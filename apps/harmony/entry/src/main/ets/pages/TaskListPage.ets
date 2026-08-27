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
  display,
  KeyboardAvoidMode,
  LengthMetrics,
  promptAction,
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
import { RemoteSession, readStr } from '../core/tasks/TaskModels';
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
import { TaskPageContent } from './TaskPage';
import { NewSessionPageContent } from './NewSessionPage';
import {
  consumeTaskSplitRouteSelection,
  isWideTaskLayout,
  TASK_SPLIT_DEFAULT_RATIO,
  TASK_SPLIT_DIVIDER_WIDTH,
  taskDetailKeyboardInset,
  taskDetailPaneWidth,
  taskListPaneWidth,
  taskSplitRatioForDrag,
} from './TaskSplitLayout';
import {
  compareTaskListLabels,
  compareTaskSessionsForList,
  resolveTaskRightStatus,
  taskActivityAt,
  taskDisplayTitle,
  taskListEntryPresentationState,
  taskListCategory,
  taskListShouldShowFloatingBarAtBoundary,
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
const SPLIT_HANDLE_WIDTH = 16;
const SPLIT_HANDLE_HEIGHT = 56;
const SPLIT_HANDLE_MARK_WIDTH = 2;
const SPLIT_HANDLE_MARK_HEIGHT = 24;
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
  @State selectedDeviceId: string = '';
  @State selectedSessionDeviceId: string = '';
  @State selectedSessionId: string = '';
  @State selectedMessageClientId: string = '';
  /** 新任务只在当前页面保留本地草稿；宽屏放在右栏，窄屏覆盖整页。 */
  @State newSessionDraftOpen: boolean = false;
  @State newSessionDraftDeviceId: string = '';
  @State scopeMenuOpen: boolean = false;
  @State sortMenuOpen: boolean = false;
  @State activeListTab: TaskListCategory = 'projects';
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
  @State foldStatus: number = -1;
  @State listPaneRatio: number = TASK_SPLIT_DEFAULT_RATIO;
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
  private projectOrderScopeGeneration: number = 0;
  private projectOrderSuppressClick: boolean = false;
  private projectDragStartY: number = 0;
  private projectDragStartIndex: number = -1;
  private projectDragStartOrder: string[] = [];
  private projectDragMoved: boolean = false;
  private dividerTouchStartX: number = 0;
  private dividerTouchStartRatio: number = TASK_SPLIT_DEFAULT_RATIO;
  private foldStatusListening: boolean = false;
  private singlePaneNavigationPending: boolean = false;
  private pageActive: boolean = false;
  /** 页面重进后，旧的刷新/任务操作 Promise 不能再改写新页面状态。 */
  private pageLifecycleGeneration: number = 0;
  private keyboardWindow: window.Window | null = null;
  private keyboardHeightListening: boolean = false;
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
  private automationsScroller: Scroller = new Scroller();
  private listTabsAppeared: boolean = false;
  private floatingBarHidden: boolean = false;
  /** 正数表示向列表末尾浏览，负数表示回看上方；方向改变时重新累计。 */
  private floatingBarScrollIntent: number = 0;
  private initialListTabIndex: number = 0;
  private foldStatusListener: (status: number) => void = (status: number): void => {
    const wasSplit = this.splitLayoutEnabled();
    this.foldStatus = status;
    this.handleSplitLayoutChange(wasSplit);
  };

  aboutToAppear(): void {
    this.pageLifecycleGeneration += 1;
    this.pageActive = true;
    this.singlePaneNavigationPending = false;
    this.taskListReconcileGeneration += 1;
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
    }
    this.hydratePreferences();
    this.initialListTabIndex = this.listTabIndex(this.activeListTab);
    this.connectionStatus = AppServices.instance.client.getStatus();
    this.observeFoldStatus();
    // KeyboardAvoidMode 是 UIContext 级状态；从新建页等单栏页面返回时，
    // 必须按当前主从布局重新声明，不能沿用上一页的 OFFSET。
    this.updateKeyboardAvoidance();
    void this.observeKeyboardHeight();

    this.unsubs.push(AppServices.instance.tasks.onChanged(() => {
      this.refreshProjection();
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
      if (status === 'online') {
        if (this.selectedDeviceId.length > 0) void this.refreshProjectOrderForScope();
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
    this.stopFoldStatusObservation();
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
  }

  onBackPress(): boolean {
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
      this.newSessionDraftOpen = false;
      this.updateKeyboardAvoidance();
      this.ensureWideSelection();
      return true;
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

  private observeFoldStatus(): void {
    if (this.foldStatusListening) return;
    try {
      if (!display.isFoldable()) return;
      this.foldStatus = Number(display.getFoldStatus());
      display.on('foldStatusChange', this.foldStatusListener);
      this.foldStatusListening = true;
    } catch (e) {
      // 非折叠设备或旧系统没有可用状态时，宽度判断仍可独立工作。
      this.foldStatus = -1;
      this.foldStatusListening = false;
    }
  }

  private stopFoldStatusObservation(): void {
    if (!this.foldStatusListening) return;
    try {
      display.off('foldStatusChange', this.foldStatusListener);
    } catch (e) {
      // 页面销毁时取消监听失败不应影响任务订阅清理。
    }
    this.foldStatusListening = false;
  }

  private refreshProjection(): void {
    const devices = AppServices.instance.tasks.deviceList;
    const next: TaskListEntry[] = [];
    for (let deviceIndex = 0; deviceIndex < devices.length; deviceIndex++) {
      const device = devices[deviceIndex];
      if (!device.remoteControlEnabled) continue;
      const sessions = AppServices.instance.tasks.getSessions(device.deviceId);
      for (let sessionIndex = 0; sessionIndex < sessions.length; sessionIndex++) {
        const session = sessions[sessionIndex];
        if (session.status === 'deleted' || session.orcaRole === 'worker') continue;
        const entry = new TaskListEntry();
        entry.key = `${device.deviceId}:${session.id}`;
        entry.deviceId = device.deviceId;
        entry.deviceName = device.deviceName;
        entry.session = session;
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
    this.devices = devices;
    this.entries = next;
    this.reconcileTaskSearchProjectKeys();
    this.collapseProjectGroupsOnce();
    this.ensureWideSelection();
    this.tryOpenPendingDeepLink();
    if (this.taskSearchActive()) this.scheduleTaskSearch();
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

  private ensureWideSelection(): void {
    if (!this.splitLayoutEnabled()) return;
    if (this.newSessionDraftOpen) return;
    if (this.taskSearchActive()) {
      // 搜索请求尚未完成时保留当前详情，避免每次输入一个字符右栏闪空；
      // 结果落地后再按当前 Tab 选择首条搜索结果。
      if (this.taskSearchStatus !== 'ready') return;
      const results = this.taskSearchResultsForCategory(this.activeListTab);
      for (let i = 0; i < results.length; i++) {
        if (results[i].deviceId === this.selectedSessionDeviceId
          && results[i].session.id === this.selectedSessionId) return;
      }
      if (results.length === 0) {
        this.selectedSessionDeviceId = '';
        this.selectedSessionId = '';
        this.selectedMessageClientId = '';
        return;
      }
      this.selectedSessionDeviceId = results[0].deviceId;
      this.selectedSessionId = results[0].session.id;
      this.selectedMessageClientId = results[0].contentMessageClientId;
      return;
    }
    const scoped = this.activeListEntries();
    for (let i = 0; i < scoped.length; i++) {
      if (scoped[i].deviceId === this.selectedSessionDeviceId
        && scoped[i].session.id === this.selectedSessionId) {
        return;
      }
    }
    if (scoped.length === 0) {
      this.selectedSessionDeviceId = '';
      this.selectedSessionId = '';
      this.selectedMessageClientId = '';
      return;
    }
    this.selectedSessionDeviceId = scoped[0].deviceId;
    this.selectedSessionId = scoped[0].session.id;
    this.selectedMessageClientId = '';
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
    this.handleSplitLayoutChange(wasSplit);
  }

  private handleSplitLayoutChange(wasSplit: boolean): void {
    const splitEnabled = this.splitLayoutEnabled();
    if (splitEnabled) this.ensureWideSelection();
    if (wasSplit && !splitEnabled && !this.newSessionDraftOpen) {
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
    return isWideTaskLayout(this.viewportWidth, this.viewportHeight, this.foldStatus);
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
    if (hostContext === undefined) return;
    try {
      const hostWindow = await window.getLastWindow(hostContext);
      if (!this.pageActive || this.keyboardHeightListening) return;
      this.keyboardWindow = hostWindow;
      hostWindow.on('keyboardHeightChange', this.keyboardHeightListener);
      this.keyboardHeightListening = true;
    } catch (_err) {
      // 监听不可用时宁可回退为全页避让，也不能让输入框被键盘遮住。
      if (this.pageActive && (this.splitLayoutEnabled() || this.newSessionDraftOpen)) {
        this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
      }
    }
  }

  private stopKeyboardHeightObservation(): void {
    if (!this.keyboardHeightListening || this.keyboardWindow === null) return;
    try {
      this.keyboardWindow.off('keyboardHeightChange', this.keyboardHeightListener);
    } catch (_err) {
      // 页面退出时监听已被系统清理，不影响后续路由恢复默认避让。
    }
    this.keyboardWindow = null;
    this.keyboardHeightListening = false;
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
    return taskDetailKeyboardInset(
      this.viewportWidth,
      this.viewportHeight,
      this.foldStatus,
      this.keyboardHeight,
    );
  }

  private newSessionKeyboardInset(): number {
    // 宽屏继续只抬右栏；窄屏草稿覆盖整页时直接消费实际键盘高度，
    // 确保正文、工具栏和发送按钮作为完整 Composer 一起停在键盘上方。
    return this.splitLayoutEnabled() ? this.detailKeyboardInset() : this.keyboardHeight;
  }

  private listPaneWidth(): number {
    return taskListPaneWidth(this.viewportWidth, this.listPaneRatio);
  }

  private detailPaneWidth(): number {
    return taskDetailPaneWidth(this.viewportWidth, this.listPaneRatio);
  }

  private selectedTaskKey(): string {
    if (this.selectedSessionDeviceId.length === 0 || this.selectedSessionId.length === 0) return '';
    return `${this.selectedSessionDeviceId}:${this.selectedSessionId}`;
  }

  private selectedTaskInstanceKey(): string {
    return `${this.selectedTaskKey()}:${this.selectedMessageClientId}`;
  }

  private entrySelected(entry: TaskListEntry): boolean {
    return this.splitLayoutEnabled() && !this.newSessionDraftOpen
      && entry.deviceId === this.selectedSessionDeviceId
      && entry.session.id === this.selectedSessionId;
  }

  private selectSession(entry: TaskListEntry): void {
    this.newSessionDraftOpen = false;
    this.updateKeyboardAvoidance();
    this.selectedSessionDeviceId = entry.deviceId;
    this.selectedSessionId = entry.session.id;
    this.selectedMessageClientId = '';
  }

  private tryOpenPendingDeepLink(): void {
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
      this.selectedSessionDeviceId = deviceId;
      this.selectedSessionId = intent.sessionId;
      this.selectedMessageClientId = intent.messageClientId;
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

  private setActiveListTab(tab: TaskListCategory): void {
    const index = this.listTabIndex(tab);
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
    this.activeListTab = category;
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
    this.floatingBarScrollIntent = 0;
    this.listTabController.applyShowAnimation(HdsAnimationMode.SCROLL_ANIMATION);
  }

  private scrollerForCategory(category: TaskListCategory): Scroller {
    if (category === 'dialogues') return this.dialoguesScroller;
    if (category === 'automations') return this.automationsScroller;
    return this.projectsScroller;
  }

  /**
   * 顶部、底部和不足一屏都属于明确边界：底栏必须出现，方向阈值只作用于列表中段。
   */
  private restoreFloatingBarAtBoundary(category: TaskListCategory): boolean {
    const scroller = this.scrollerForCategory(category);
    const yOffset = scroller.currentOffset().yOffset;
    if (!taskListShouldShowFloatingBarAtBoundary(yOffset, scroller.isAtEnd())) return false;
    this.floatingBarScrollIntent = 0;
    this.showFloatingBar();
    return true;
  }

  private handleTaskListScroll(
    category: TaskListCategory,
    scrollOffset: number,
    scrollState: ScrollState,
  ): void {
    // 惯性抵达边界也应立即恢复底栏；只有列表中段继续沿用手指方向判断。
    if (this.restoreFloatingBarAtBoundary(category)) return;
    // 只响应手指拖动；惯性与边缘反馈均为 Fling，不能反向改写用户刚表达的浏览意图。
    if (scrollState !== ScrollState.Scroll) {
      this.floatingBarScrollIntent = 0;
      return;
    }
    if (Math.abs(scrollOffset) < FLOATING_BAR_SCROLL_NOISE) return;

    // 官方语义：内容向上（用户向列表末尾浏览）为正，内容向下（回看上方）为负。
    if (scrollOffset > 0) {
      if (this.floatingBarScrollIntent < 0) this.floatingBarScrollIntent = 0;
      this.floatingBarScrollIntent += scrollOffset;
      if (this.floatingBarScrollIntent >= FLOATING_BAR_HIDE_DISTANCE) {
        this.hideFloatingBar();
        this.floatingBarScrollIntent = 0;
      }
      return;
    }

    if (this.floatingBarScrollIntent > 0) this.floatingBarScrollIntent = 0;
    this.floatingBarScrollIntent += scrollOffset;
    if (this.floatingBarScrollIntent <= -FLOATING_BAR_SHOW_DISTANCE) {
      this.showFloatingBar();
      this.floatingBarScrollIntent = 0;
    }
  }

  private handleTaskListDragRelease(category: TaskListCategory, velocity: number): void {
    // 内容不足一屏时没有有效滚动位移，但松手仍能通过真实边界恢复底栏。
    if (this.restoreFloatingBarAtBoundary(category)) return;
    // 短距离快速甩动可能来不及累计位移，用较克制的速度门槛补齐同一方向语义。
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

  private handleDividerTouch(event: TouchEvent): void {
    if (event.type === TouchType.Cancel) {
      return;
    }
    if (event.changedTouches.length === 0) return;
    const point = event.changedTouches[0];
    if (event.type === TouchType.Down) {
      this.dividerTouchStartX = point.displayX;
      this.dividerTouchStartRatio = this.listPaneRatio;
      return;
    }
    if (event.type === TouchType.Move) {
      // 直接拖拽跟手，不加缓动（跟随手指本身就是反馈）。
      this.listPaneRatio = taskSplitRatioForDrag(
        this.viewportWidth,
        this.dividerTouchStartRatio,
        point.displayX - this.dividerTouchStartX,
      );
      return;
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
    if (this.splitLayoutEnabled()) return;
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
    this.selectedSessionDeviceId = result.deviceId;
    this.selectedSessionId = session.id;
    this.selectedMessageClientId = result.contentMessageClientId;
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

  private openNewSession(): void {
    this.newSessionDraftDeviceId = this.selectedDeviceId;
    this.newSessionDraftOpen = true;
    this.updateKeyboardAvoidance();
  }

  /** 菜单开合统一走轻量可见性动效，保证浮层进退场完整播放。 */
  private animateMenu(apply: () => void): void {
    uiAnimateFastState(this.getUIContext(), apply);
  }

  private openDeviceScopeMenu(): void {
    this.animateMenu(() => {
      this.sortMenuOpen = false;
      this.scopeMenuOpen = true;
    });
  }

  private closeScopeMenu(): void {
    this.animateMenu(() => {
      this.scopeMenuOpen = false;
    });
  }

  private openSortMenu(): void {
    this.animateMenu(() => {
      this.scopeMenuOpen = false;
      this.sortMenuOpen = true;
    });
  }

  private closeSortMenu(): void {
    this.animateMenu(() => {
      this.sortMenuOpen = false;
    });
  }

  private selectSortMode(mode: TaskListSortMode): void {
    this.animateMenu(() => {
      this.sortMode = mode;
      this.sortMenuOpen = false;
    });
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
    promptAction.showToast({ message: this.v12String('v12_project_order_sync_failed') });
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

  private sortMenuTop(): number {
    return 60 + (this.connectionStatus === 'online' ? 0 : 36) + 4;
  }

  private sortMenuRightInset(): number {
    return LIST_INSET + 3 * 40;
  }

  private selectDevice(deviceId: string): void {
    this.animateMenu(() => {
      this.selectedDeviceId = deviceId;
      this.reconcileTaskSearchProjectKeys();
      this.scopeMenuOpen = false;
    });
    void this.refreshProjectOrderForScope();
    this.ensureWideSelection();
    if (this.taskSearchActive()) this.scheduleTaskSearch();
    this.persistPreferences();
  }

  private selectedDeviceLabel(): string {
    if (this.selectedDeviceId.length === 0) return '所有任务';
    for (let i = 0; i < this.devices.length; i++) {
      if (this.devices[i].deviceId === this.selectedDeviceId) {
        return this.devices[i].deviceName;
      }
    }
    const resolved = AppServices.instance.tasks.getDeviceName(this.selectedDeviceId);
    return resolved.length > 0 ? resolved : this.selectedDeviceNameHint;
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
        device.deviceName,
        AppServices.instance.tasks.getSessions(device.deviceId),
      );
      for (let projectIndex = 0; projectIndex < projects.length; projectIndex++) {
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
      origin.deviceName = device.deviceName;
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

  private scheduleTaskSearch(): void {
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
    this.animateMenu(() => {
      this.scopeMenuOpen = false;
      this.sortMenuOpen = false;
      this.taskSearchFilterOpen = true;
    });
  }

  private closeTaskSearchFilter(): void {
    this.animateMenu(() => {
      this.taskSearchFilterOpen = false;
    });
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
            promptAction.showToast({ message: '连接电脑后才能刷新任务' });
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
      if (visible && !success) promptAction.showToast({ message: '部分任务刷新失败，请重试' });
      return success;
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
    if (!ok) promptAction.showToast({ message: '任务更新失败，请重试' });
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
    this.getUIContext().showAlertDialog({
      title: `处理 ${count} 个任务？`,
      message: action === 'delete' ? '选中的任务将被删除。' : '将对选中的适用任务执行此操作。',
      primaryButton: {
        value: '取消',
        action: () => {
        },
      },
      secondaryButton: {
        value: '继续',
        fontColor: action === 'delete' ? $r('app.color.danger') : $r('app.color.text_primary'),
        action: () => {
          if (!this.pageActive || lifecycleGeneration !== this.pageLifecycleGeneration) return;
          void this.applyBulkAction(action, lifecycleGeneration, keys);
        },
      },
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
        promptAction.showToast({ message: `${parts.join('，')}，已保留选择` });
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
        && taskListCategory(scoped[i].session) === category) {
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

  private projectGroupsFrom(entries: TaskListEntry[]): TaskProjectGroup[] {
    const groups: Map<string, TaskProjectGroup> = new Map();
    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      const session = entry.session;
      if (taskListCategory(session) !== 'projects') continue;
      const key = taskProjectOrderKey(entry.deviceId, session.workingDir);
      let group = groups.get(key);
      if (group === undefined) {
        group = new TaskProjectGroup();
        group.key = key;
        group.deviceId = entry.deviceId;
        group.workingDir = session.workingDir;
        group.title = taskProjectName(session.workingDir);
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
    return out;
  }

  private dialogueEntries(): TaskListEntry[] {
    const out: TaskListEntry[] = [];
    const entries = this.regularEntries();
    for (let i = 0; i < entries.length; i++) {
      if (taskListCategory(entries[i].session) === 'dialogues') out.push(entries[i]);
    }
    return out;
  }

  private automationEntries(): TaskListEntry[] {
    const out: TaskListEntry[] = [];
    const entries = this.regularEntries();
    for (let i = 0; i < entries.length; i++) {
      if (taskListCategory(entries[i].session) === 'automations') out.push(entries[i]);
    }
    return out;
  }

  private flatCategoryEntries(category: TaskListCategory): TaskListEntry[] {
    if (category === 'dialogues') return this.dialogueEntries();
    if (category === 'automations') return this.automationEntries();
    return [];
  }

  private sessionEntryRenderKey(prefix: string, entry: TaskListEntry): string {
    const state = taskListEntryPresentationState(entry.session, this.taskRightStatusKind(entry));
    return `${prefix}:${entry.key}:state:${state.length}:${state}`;
  }

  private projectGroupRenderKey(group: TaskProjectGroup): string {
    // 外层项目节点也会捕获旧 entries；成员不仅新增/移除，任一行的可见状态变化
    // 都必须进入外层 key，否则内部 ForEach 连重新计算 key 的机会都没有。
    let key = `project:${group.key}`;
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
      Row() {
        this.taskListPane()
        if (this.splitLayoutEnabled()) {
          Column() {
            this.detailPane()
          }
          .width(this.detailPaneWidth())
          .height('100%')
        }
      }
      .width('100%')
      .height('100%')

      // 新任务草稿始终由同一个节点持有：窄屏覆盖整页，宽屏只覆盖详情栏。
      // 旋转或折叠只更新尺寸，避免组件重建时释放尚未发送的附件。
      if (this.newSessionDraftOpen) {
        NewSessionPageContent({
          paneDeviceId: this.newSessionDraftDeviceId,
          paneKeyboardInset: this.newSessionKeyboardInset(),
          paneComposerBottomInset: this.detailComposerBottomInset(),
          embedded: this.splitLayoutEnabled(),
          onClose: (): void => {
            this.newSessionDraftOpen = false;
            this.updateKeyboardAvoidance();
            this.ensureWideSelection();
          },
          onSessionStarted: (deviceId: string, sessionId: string): void => {
            this.newSessionDraftOpen = false;
            this.updateKeyboardAvoidance();
            this.selectedSessionDeviceId = deviceId;
            this.selectedSessionId = sessionId;
            this.selectedMessageClientId = '';
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

      if (this.splitLayoutEnabled()) {
        this.splitDivider()
      }

      if (this.scopeMenuOpen) {
        this.scopeMenuLayer()
      }
      if (this.sortMenuOpen) {
        this.sortMenuLayer()
      }
      if (this.taskSearchFilterOpen) {
        this.taskSearchFilterLayer()
      }
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
      if (this.searchOpen) {
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
          '对话',
          $r('sys.symbol.ellipsis_message'),
        ))

        TabContent() {
          this.taskListTabPage('automations')
        }
        .clip(false)
        .tabBar(this.taskListTabBarStyle(
          '自动化',
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
  }

  @Builder
  taskListTabPage(category: TaskListCategory) {
    Column() {
      if (this.taskSearchActive()) {
        if (this.taskSearchStatus === 'searching') {
          this.buildTaskSearchLoading()
        } else if (this.taskSearchResultsForCategory(category).length === 0) {
          this.activeTabEmptyState(category)
        } else {
          this.buildTaskSearchEntries(category)
        }
      } else if (this.scopedEntries().length === 0) {
        this.buildTaskListEmpty()
      } else {
        this.buildTaskListEntries(category)
      }
    }
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

      Row() {
        Row()
          .width(SPLIT_HANDLE_MARK_WIDTH)
          .height(SPLIT_HANDLE_MARK_HEIGHT)
          .backgroundColor($r('app.color.text_tertiary'))
          .borderRadius(UI_RADIUS_PILL)
      }
      .justifyContent(FlexAlign.Center)
      .width(SPLIT_HANDLE_WIDTH)
      .height(SPLIT_HANDLE_HEIGHT)
      .backgroundColor($r('app.color.bg_chip'))
      .border({ width: 1, color: $r('app.color.border') })
      .borderRadius(UI_RADIUS_PILL)
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
    if (this.selectedTaskKey().length === 0) {
      this.emptyDetailPane()
    } else {
      ForEach([this.selectedTaskInstanceKey()], (key: string) => {
        TaskPageContent({
          paneDeviceId: this.selectedSessionDeviceId,
          paneSessionId: this.selectedSessionId,
          paneMessageClientId: this.selectedMessageClientId,
          paneComposerBottomInset: this.detailComposerBottomInset(),
          paneKeyboardInset: this.detailKeyboardInset(),
        })
          .transition(uiRevealTransition())
      }, (key: string) => key)
    }
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

      this.headerSymbolButton(
        $r('sys.symbol.slider_horizontal_2'),
        () => this.openSortMenu(),
        '排序',
      )
      this.refreshHeaderButton()
      this.headerSymbolButton(
        $r('sys.symbol.magnifyingglass'),
        () => this.toggleSearch(),
        '搜索',
      )
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

  @Builder
  refreshHeaderButton() {
    Button() {
      if (this.refreshing) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color($r('app.color.text_secondary'))
      } else {
        SymbolGlyph($r('sys.symbol.arrow_clockwise'))
          .fontSize(18)
          .fontColor([$r('app.color.text_primary')])
      }
    }
    .type(ButtonType.Circle)
    .width(40)
    .height(40)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .clickEffect(UI_ICON_CLICK_EFFECT)
    .enabled(!this.refreshing)
    .accessibilityText(this.refreshing ? '正在刷新任务' : '刷新任务')
    .onClick(() => {
      void this.refreshTaskList(true);
    })
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
  }

  @Builder
  buildTaskListEmpty() {
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
    .onAppear(() => this.showFloatingBar())
  }

  @Builder
  buildTaskListEntries(category: TaskListCategory) {
    // 滑动只负责露出操作按钮；不要配置 actionAreaDistance / onAction，
    // 避免长距离滑动松手时直接置顶或归档，所有操作都必须由按钮点击触发。
    List({ scroller: this.scrollerForCategory(category) }) {
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
    .onDidScroll((scrollOffset: number, scrollState: ScrollState) => {
      this.handleTaskListScroll(category, scrollOffset, scrollState);
    })
    .onWillStopDragging((velocity: number) => {
      this.handleTaskListDragRelease(category, velocity);
    })
    .onReachStart(() => {
      this.restoreFloatingBarAtBoundary(category);
    })
    .onReachEnd(() => {
      // 官方 onReachEnd 在短列表首次布局和内容变短时也会触发；再用 isAtEnd
      // 精确复核，避免最后一行刚进入视口就过早显示底栏。
      this.restoreFloatingBarAtBoundary(category);
    })
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
  buildTaskSearchEntries(category: TaskListCategory) {
    List({ scroller: this.scrollerForCategory(category) }) {
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
    .onDidScroll((scrollOffset: number, scrollState: ScrollState) => {
      this.handleTaskListScroll(category, scrollOffset, scrollState);
    })
    .onReachStart(() => this.restoreFloatingBarAtBoundary(category))
    .onReachEnd(() => this.restoreFloatingBarAtBoundary(category))
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
      this.agentMark(result.session.agentKind)
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
    const device = result.deviceName.length > 0
      ? result.deviceName : this.v12String('v12_device');
    const project = result.session.workingDir.length > 0
      ? taskProjectName(result.session.workingDir)
      : taskListCategory(result.session) === 'automations'
        ? this.v12String('v12_automation') : this.v12String('v12_dialogue');
    return `${device} · ${project}`;
  }

  private taskSearchResultRenderKey(result: TaskSearchResult): string {
    return `${result.deviceId}:${result.session.id}:${result.matchKind}:${result.contentMessageClientId}`;
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
        this.agentMark(entry.session.agentKind)
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
      Text(entry.session.status === 'archived' ? '恢复' : '归档')
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

  @Builder
  projectGroupHeader(group: TaskProjectGroup) {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.folder'))
        .fontSize(17)
        .fontColor([$r('app.color.text_secondary')])
      Text(group.title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(`${group.entries.length}`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
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

  @Builder
  agentMark(agentKind: string) {
    Stack({ alignContent: Alignment.Center }) {
      Text(this.agentMarkText(agentKind))
        .fontSize(agentKind === 'pi' ? 12 : 9)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
    }
    .width(24)
    .height(24)
    .backgroundColor($r('app.color.bg_chip'))
    .borderRadius(UI_RADIUS_CONTROL)
  }

  private agentMarkText(agentKind: string): string {
    if (agentKind === 'cc') return 'CC';
    if (agentKind === 'codex') return 'CX';
    if (agentKind === 'pi') return 'Pi';
    return 'AI';
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
      this.bulkActionButton('恢复', () => this.bulkAction('restore'))
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

  @Builder
  sortMenuLayer() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.task_list_overlay'))
        .transition(uiRevealTransition())
        .onClick(() => {
          this.closeSortMenu();
        })

      Row() {
        Column() {
          this.sortMenuOption('最近优先', 'recency')
          this.sortMenuOption('字母排序', 'alphabetic')
          this.sortMenuOption('默认排序', 'default')
          if (this.activeListTab === 'projects') {
            Divider()
              .strokeWidth(1)
              .color($r('app.color.border'))
              .margin({ top: 4, bottom: 4 })
            Text($r('app.string.v12_project_order'))
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .margin({ left: 10, top: 2, bottom: 2 })
              .alignSelf(ItemAlign.Start)
            this.projectOrderMenuOption(this.v12String('v12_recent_project_order'), 'activity')
            this.projectOrderMenuOption(this.v12String('v12_custom_project_order'), 'custom')
            if (this.projectOrderSyncing) {
              Text($r('app.string.v12_syncing_project_order'))
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ left: 10, top: 2, bottom: 4 })
            } else if (this.selectedDeviceId.length > 0 && !this.projectOrderHostAvailable) {
              Text($r('app.string.v12_local_project_order'))
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ left: 10, top: 2, bottom: 4 })
            } else if (this.displayedProjectOrderMode() === 'custom') {
              Text($r('app.string.v12_drag_project_order'))
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .margin({ left: 10, top: 2, bottom: 4 })
            }
            this.projectExpandMenuOption()
          }
        }
        .width(220)
        .padding(8)
        .backgroundColor($r('app.color.task_list_menu_surface'))
        .border({ width: 1, color: $r('app.color.border') })
        .borderRadius(UI_RADIUS_CONTAINER)
        .transition(uiOverlayTransition())
        .onClick(() => {
          // 截住面板区域点击，避免穿透到遮罩。
        })
      }
      .width(this.splitLayoutEnabled() ? this.listPaneWidth() : '100%')
      .padding({ right: this.sortMenuRightInset() })
      .margin({ top: this.sortMenuTop() })
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  sortMenuOption(label: string, mode: TaskListSortMode) {
    Row({ space: 10 }) {
      this.menuCheck(this.sortMode === mode)
      Text(label)
        .fontSize(15)
        .fontWeight(this.sortMode === mode ? FontWeight.Medium : FontWeight.Regular)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .height(44)
    .padding({ left: 10, right: 12 })
    .backgroundColor(this.sortMode === mode ? $r('app.color.bg_chip') : Color.Transparent)
    .borderRadius(UI_RADIUS_CONTROL)
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(() => this.selectSortMode(mode))
  }

  @Builder
  projectOrderMenuOption(label: string, mode: TaskProjectOrderMode) {
    Row({ space: 10 }) {
      this.menuCheck(this.displayedProjectOrderMode() === mode)
      Text(label)
        .fontSize(15)
        .fontWeight(this.displayedProjectOrderMode() === mode
          ? FontWeight.Medium : FontWeight.Regular)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .height(44)
    .padding({ left: 10, right: 12 })
    .backgroundColor(this.displayedProjectOrderMode() === mode
      ? $r('app.color.bg_chip') : Color.Transparent)
    .borderRadius(UI_RADIUS_CONTROL)
    .enabled(!this.projectOrderSyncing)
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(() => this.selectProjectOrderMode(mode))
  }

  @Builder
  projectExpandMenuOption() {
    Row({ space: 10 }) {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(this.allProjectsCollapsed()
          ? $r('sys.symbol.chevron_down')
          : $r('sys.symbol.chevron_up'))
          .fontSize(14)
          .fontColor([$r('app.color.text_secondary')])
      }
      .width(18)
      .height(18)
      Text(this.allProjectsCollapsed()
        ? $r('app.string.v12_expand_project') : $r('app.string.v12_collapse_project'))
        .fontSize(15)
        .fontColor(this.projectGroups().length > 0
          ? $r('app.color.text_primary')
          : $r('app.color.text_tertiary'))
        .layoutWeight(1)
    }
    .width('100%')
    .height(44)
    .padding({ left: 10, right: 12 })
    .backgroundColor(Color.Transparent)
    .borderRadius(UI_RADIUS_CONTROL)
    .enabled(this.projectGroups().length > 0)
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(() => this.toggleAllProjectsFromMenu())
  }

  private taskSearchFilterTop(): number {
    return 60 + (this.connectionStatus === 'online' ? 0 : 36) + 4;
  }

  private taskSearchFilterWidth(): number {
    const available = this.splitLayoutEnabled() ? this.listPaneWidth() : this.viewportWidth;
    if (available <= 0) return 300;
    return Math.max(280, available - 32);
  }

  private taskSearchFilterMaxHeight(): number {
    if (this.viewportHeight <= 0) return 520;
    return Math.max(240, this.viewportHeight - this.taskSearchFilterTop() - 16);
  }

  @Builder
  taskSearchFilterLayer() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width(this.splitLayoutEnabled() ? this.listPaneWidth() : '100%')
        .height('100%')
        .backgroundColor($r('app.color.task_list_overlay'))
        .transition(uiRevealTransition())
        .onClick(() => this.closeTaskSearchFilter())

      Column() {
        Row({ space: 8 }) {
          Text($r('app.string.v12_search_filter'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
          if (this.taskSearchFilterCount() > 0) {
            Button($r('app.string.v12_reset'))
              .height(32)
              .padding({ left: 10, right: 10 })
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .backgroundColor(Color.Transparent)
              .borderRadius(UI_RADIUS_PILL)
              .onClick(() => this.resetTaskSearchFilters())
          }
          Button($r('app.string.v12_done'))
            .height(32)
            .padding({ left: 12, right: 12 })
            .fontSize(12)
            .fontColor($r('app.color.chat_cta_text'))
            .backgroundColor($r('app.color.chat_cta'))
            .borderRadius(UI_RADIUS_PILL)
            .onClick(() => this.closeTaskSearchFilter())
        }
        .width('100%')
        .height(44)
        .padding({ left: 10, right: 10 })

        Scroll() {
          Column() {
            this.taskSearchFilterSectionTitle(this.v12String('v12_search_sort'))
            this.taskSearchFilterOption(this.v12String('v12_search_relevance'), this.taskSearchSortBy === 'relevance',
              () => this.selectTaskSearchSort('relevance'))
            this.taskSearchFilterOption(this.v12String('v12_search_recent_activity'), this.taskSearchSortBy === 'activityDesc',
              () => this.selectTaskSearchSort('activityDesc'))
            this.taskSearchFilterOption(this.v12String('v12_search_earliest_activity'), this.taskSearchSortBy === 'activityAsc',
              () => this.selectTaskSearchSort('activityAsc'))
            Divider()
              .strokeWidth(1)
              .color($r('app.color.border'))
              .margin({ top: 6, bottom: 6 })

            this.taskSearchFilterSectionTitle(this.v12String('v12_search_status'))
            this.taskSearchFilterOption(this.v12String('v12_search_all_status'), this.taskSearchStatusFilter === 'all',
              () => this.selectTaskSearchStatus('all'))
            this.taskSearchFilterOption(this.v12String('v12_search_active'), this.taskSearchStatusFilter === 'active',
              () => this.selectTaskSearchStatus('active'))
            this.taskSearchFilterOption(this.v12String('v12_search_archived'), this.taskSearchStatusFilter === 'archived',
              () => this.selectTaskSearchStatus('archived'))
            Divider()
              .strokeWidth(1)
              .color($r('app.color.border'))
              .margin({ top: 6, bottom: 6 })

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
            Divider()
              .strokeWidth(1)
              .color($r('app.color.border'))
              .margin({ top: 6, bottom: 6 })

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
            Divider()
              .strokeWidth(1)
              .color($r('app.color.border'))
              .margin({ top: 6, bottom: 6 })

            this.taskSearchFilterSectionTitle(this.v12String('v12_search_project'))
            ForEach(this.taskSearchProjects(), (project: TaskSearchProjectOption) => {
              this.taskSearchFilterOption(
                `${project.title} · ${project.deviceName}`,
                this.taskSearchProjectKeys.indexOf(project.key) >= 0,
                () => this.toggleTaskSearchProject(project.key),
                `${project.count}`,
              )
            }, (project: TaskSearchProjectOption) => `search-project:${project.key}`)
            if (this.taskSearchProjects().length === 0) {
              Text($r('app.string.v12_no_synced_projects'))
                .fontSize(13)
                .fontColor($r('app.color.text_tertiary'))
                .padding({ left: 10, top: 8, bottom: 8 })
            }
          }
          .width('100%')
          .padding({ left: 8, right: 8, bottom: 8 })
        }
        .width('100%')
        .constraintSize({ maxHeight: this.taskSearchFilterMaxHeight() })
        .scrollBar(BarState.Auto)
      }
      .width(this.taskSearchFilterWidth())
      .margin({ left: LIST_INSET, top: this.taskSearchFilterTop() })
      .backgroundColor($r('app.color.task_list_menu_surface'))
      .border({ width: 1, color: $r('app.color.border') })
      .borderRadius(UI_RADIUS_CONTAINER)
      .transition(uiOverlayTransition())
      .onClick(() => {
        // 截住面板区域点击，避免关闭筛选层。
      })
    }
    .width(this.splitLayoutEnabled() ? this.listPaneWidth() : '100%')
    .height('100%')
  }

  @Builder
  taskSearchFilterSectionTitle(label: string) {
    Text(label)
      .fontSize(11)
      .fontColor($r('app.color.text_tertiary'))
      .height(28)
      .padding({ left: 10, top: 8 })
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

  @Builder
  scopeMenuLayer() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.task_list_overlay'))
        .transition(uiRevealTransition())
        .onClick(() => {
          this.closeScopeMenu();
        })

      Column() {
        Scroll() {
          Column() {
            this.scopeMenuAllRow()
            ForEach(this.devices, (device: PresenceSnapshot) => {
              this.scopeMenuDeviceRow(device)
            }, (device: PresenceSnapshot) => `scope:${device.deviceId}`)
          }
          .width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: 288 })
        .scrollBar(BarState.Off)
      }
      .width(280)
      .padding(8)
      .margin({ left: LIST_INSET, top: 52 })
      .backgroundColor($r('app.color.task_list_menu_surface'))
      .border({ width: 1, color: $r('app.color.border') })
      .borderRadius(UI_RADIUS_CONTAINER)
      .transition(uiOverlayTransition())
      .onClick(() => {
        // 截住面板区域点击，避免穿透到遮罩。
      })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  scopeMenuAllRow() {
    Row({ space: 10 }) {
      this.menuCheck(this.selectedDeviceId.length === 0)
      SymbolGlyph($r('sys.symbol.rectangle_stack'))
        .fontSize(17)
        .fontColor([$r('app.color.text_secondary')])
        .width(22)
      Text('所有任务')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .height(48)
    .padding({ left: 10, right: 12 })
    .backgroundColor(this.selectedDeviceId.length === 0
      ? $r('app.color.bg_chip')
      : Color.Transparent)
    .borderRadius(UI_RADIUS_CONTROL)
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(() => this.selectDevice(''))
  }

  @Builder
  scopeMenuDeviceRow(device: PresenceSnapshot) {
    Row({ space: 10 }) {
      this.menuCheck(this.selectedDeviceId === device.deviceId)
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.rectangle_stack'))
          .fontSize(17)
          .fontColor([$r('app.color.text_secondary')])
        Circle()
          .width(7)
          .height(7)
          .fill(this.deviceCanOpen(device)
            ? $r('app.color.success')
            : $r('app.color.text_tertiary'))
          .margin({ left: 15, top: 15 })
      }
      .width(22)
      .height(22)
      Text(device.deviceName)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .height(48)
    .padding({ left: 10, right: 12 })
    .backgroundColor(this.selectedDeviceId === device.deviceId
      ? $r('app.color.bg_chip')
      : Color.Transparent)
    .borderRadius(UI_RADIUS_CONTROL)
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(() => this.selectDevice(device.deviceId))
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
