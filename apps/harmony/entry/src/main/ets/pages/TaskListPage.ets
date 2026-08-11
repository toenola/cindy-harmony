/**
 * 任务聚合首页。
 *
 * 对齐 iOS：首页直接聚合所有可控制电脑的任务，标题下拉可按设备筛选并切换项目分组；
 * 页面存活期间订阅各设备的 sessions topic，列表数据始终来自被控端权威快照。
 *
 * 视觉遵循 Cindy 设计系统：页面平坦 Surface、1px Board 分隔、12vp 容器圆角、
 * 胶囊交互元素；行点击使用系统 clickEffect 弹性反馈，菜单淡入淡出。
 */

import { accessibility } from '@kit.AccessibilityKit';
import { display, promptAction, router } from '@kit.ArkUI';
import { AppServices } from '../core/AppServices';
import { PresenceSnapshot } from '../core/device-link/DlProtocol';
import { RemoteSession, readStr } from '../core/tasks/TaskModels';
import { SessionLiveActivity, SessionMetaPatch } from '../core/tasks/TaskStore';
import { TaskListPreferences } from '../core/tasks/TaskListPreferenceStore';
import {
  TASK_LIST_RECONCILE_INTERVAL_MS,
  TaskListReconcileBackoff,
} from '../core/tasks/TaskListReconcilePolicy';
import { TaskPageContent } from './TaskPage';
import {
  isWideTaskLayout,
  TASK_SPLIT_DEFAULT_RATIO,
  taskListPaneWidth,
  taskSplitRatioForDrag,
} from './TaskSplitLayout';
import {
  compareTaskListLabels,
  compareTaskSessionsForList,
  taskActivityAt,
  taskDisplayTitle,
  taskListCategory,
  TaskListCategory,
  TaskListSortMode,
  taskPreviewText,
  taskProjectKey,
  taskProjectName,
  taskRelativeTime,
  taskVisibleInTaskList,
} from './TaskListPresentation';
import {
  UI_ICON_CLICK_EFFECT,
  UI_LIST_CLICK_EFFECT,
  UI_CURVE_MOVE,
  UI_MOTION_BASE,
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
const LIST_TAB_SWIPER_ID = 'task-list-tab-swiper';
const LIST_TAB_FRAME_RATE: ExpectedFrameRateRange = {
  min: 60,
  max: 120,
  expected: 120,
};
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
  @State scopeMenuOpen: boolean = false;
  @State sortMenuOpen: boolean = false;
  @State activeListTab: TaskListCategory = 'projects';
  @State sortMode: TaskListSortMode = 'recency';
  @State searchOpen: boolean = false;
  @State searchQuery: string = '';
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
  @State foldStatus: number = -1;
  @State listPaneRatio: number = TASK_SPLIT_DEFAULT_RATIO;
  @State dividerActive: boolean = false;

  private routeParamsInitialized: boolean = false;
  private unsubs: Array<() => void> = [];
  private clockTimer: number = -1;
  private taskListReconcileTimer: number = -1;
  private taskListLoadInFlight: Map<string, Promise<boolean>> = new Map();
  private taskListReconcileBackoff: TaskListReconcileBackoff = new TaskListReconcileBackoff();
  private taskListReconcileGeneration: number = 0;
  private dividerTouchStartX: number = 0;
  private dividerTouchStartRatio: number = TASK_SPLIT_DEFAULT_RATIO;
  private foldStatusListening: boolean = false;
  private listTabSwiperController: SwiperController = new SwiperController();
  private listTabSwiperAppeared: boolean = false;
  private initialListTabIndex: number = 0;
  private foldStatusListener: (status: number) => void = (status: number): void => {
    this.foldStatus = status;
    this.ensureWideSelection();
  };

  aboutToAppear(): void {
    this.taskListReconcileGeneration += 1;
    if (!this.routeParamsInitialized) {
      const params = (router.getParams() ?? {}) as Record<string, Object>;
      this.selectedDeviceId = readStr(params, 'deviceId');
      this.selectedSessionDeviceId = readStr(params, 'deviceId');
      this.selectedSessionId = readStr(params, 'sessionId');
      this.routeParamsInitialized = true;
    }
    this.hydratePreferences();
    this.initialListTabIndex = this.listTabIndex(this.activeListTab);
    this.connectionStatus = AppServices.instance.client.getStatus();
    this.observeFoldStatus();

    this.unsubs.push(AppServices.instance.tasks.onChanged(() => {
      this.refreshProjection();
    }));
    this.unsubs.push(AppServices.instance.interactions.onChanged(() => {
      this.refreshProjection();
    }));
    this.unsubs.push(AppServices.instance.onStatus((status: string) => {
      this.connectionStatus = status;
    }));
    this.unsubs.push(AppServices.instance.onDeepLink(() => {
      this.tryOpenPendingDeepLink();
    }));

    this.refreshProjection();
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
    this.taskListReconcileGeneration += 1;
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
    this.stopFoldStatusObservation();
    this.listTabSwiperAppeared = false;
    void AppServices.instance.taskListPreferences.flush();
    this.scopeMenuOpen = false;
    this.sortMenuOpen = false;
  }

  onBackPress(): boolean {
    if (this.scopeMenuOpen) {
      this.closeScopeMenu();
      return true;
    }
    if (this.sortMenuOpen) {
      this.closeSortMenu();
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
    this.collapseProjectGroupsOnce();
    this.ensureWideSelection();
    this.tryOpenPendingDeepLink();
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
    if (!isWideTaskLayout(this.viewportWidth, this.foldStatus)) return;
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
    const width = typeof widthValue === 'number' ? widthValue : 0;
    if (!Number.isFinite(width) || width <= 0 || width === this.viewportWidth) return;
    this.viewportWidth = width;
    this.ensureWideSelection();
  }

  private splitLayoutEnabled(): boolean {
    return isWideTaskLayout(this.viewportWidth, this.foldStatus);
  }

  private listPaneWidth(): number {
    return taskListPaneWidth(this.viewportWidth, this.listPaneRatio);
  }

  private selectedTaskKey(): string {
    if (this.selectedSessionDeviceId.length === 0 || this.selectedSessionId.length === 0) return '';
    return `${this.selectedSessionDeviceId}:${this.selectedSessionId}`;
  }

  private selectedTaskInstanceKey(): string {
    return `${this.selectedTaskKey()}:${this.selectedMessageClientId}`;
  }

  private entrySelected(entry: TaskListEntry): boolean {
    return this.splitLayoutEnabled()
      && entry.deviceId === this.selectedSessionDeviceId
      && entry.session.id === this.selectedSessionId;
  }

  private selectSession(entry: TaskListEntry): void {
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
      this.setActiveListTab(taskListCategory(targetSession), false);
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

  private selectListTab(tab: TaskListCategory): void {
    if (this.activeListTab === tab) return;
    this.setActiveListTab(tab, true);
    this.ensureWideSelection();
    this.persistPreferences();
  }

  private setActiveListTab(tab: TaskListCategory, animate: boolean): void {
    const index = this.listTabIndex(tab);
    this.activeListTab = tab;
    if (!this.listTabSwiperAppeared) {
      this.initialListTabIndex = index;
      return;
    }
    this.listTabSwiperController.changeIndex(
      index,
      animate && this.listTabIndicatorDuration() > 0,
    );
  }

  private listTabIndex(tab: TaskListCategory): number {
    if (tab === 'dialogues') return 1;
    if (tab === 'automations') return 2;
    return 0;
  }

  private listTabIndicatorTranslateX(): string {
    if (this.activeListTab === 'dialogues') return '100%';
    if (this.activeListTab === 'automations') return '200%';
    return '0%';
  }

  private listTabIndicatorDuration(): number {
    try {
      return accessibility.isAnimationReduceEnabledSync() ? 0 : UI_MOTION_BASE;
    } catch (_err) {
      return UI_MOTION_BASE;
    }
  }

  private handleListTabSwiperAppear(): void {
    this.listTabSwiperAppeared = true;
    this.listTabSwiperController.changeIndex(this.listTabIndex(this.activeListTab), false);
    try {
      const scenes = this.getUIContext().requireDynamicSyncScene(LIST_TAB_SWIPER_ID);
      for (let i = 0; i < scenes.length; i++) {
        scenes[i].setFrameRateRange(LIST_TAB_FRAME_RATE);
      }
    } catch (_err) {
      // 不支持动态帧率场景的设备仍使用系统原生 Swiper 动画。
    }
  }

  private handleDividerTouch(event: TouchEvent): void {
    if (event.type === TouchType.Cancel) {
      this.dividerActive = false;
      return;
    }
    if (event.changedTouches.length === 0) return;
    const point = event.changedTouches[0];
    if (event.type === TouchType.Down) {
      this.dividerTouchStartX = point.displayX;
      this.dividerTouchStartRatio = this.listPaneRatio;
      this.dividerActive = true;
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
    if (event.type === TouchType.Up) {
      this.dividerActive = false;
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

  private openSettings(): void {
    router.pushUrl({ url: 'pages/SettingsPage' });
  }

  private openNewSession(): void {
    router.pushUrl({
      url: 'pages/NewSessionPage',
      params: { deviceId: this.selectedDeviceId },
    });
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

  private sortMenuTop(): number {
    return 60 + (this.connectionStatus === 'online' ? 0 : 36) + 52;
  }

  private selectDevice(deviceId: string): void {
    this.animateMenu(() => {
      this.selectedDeviceId = deviceId;
      this.scopeMenuOpen = false;
    });
    this.ensureWideSelection();
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

  private toggleSearch(): void {
    uiAnimateFastState(this.getUIContext(), () => {
      this.searchOpen = !this.searchOpen;
      if (!this.searchOpen) this.searchQuery = '';
    });
    this.ensureWideSelection();
    this.persistPreferences();
  }

  private async refreshTaskList(visible: boolean): Promise<boolean> {
    if (this.refreshing) return false;
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
          if (visible) promptAction.showToast({ message: '连接电脑后才能刷新任务' });
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
      for (let i = 0; i < outcomes.length; i++) {
        if (outcomes[i]) loadedCount += 1;
      }
      const success = deviceSnapshotLoaded && (eligibleCount === 0 || loadedCount === eligibleCount);
      if (visible && !success) promptAction.showToast({ message: '部分任务刷新失败，请重试' });
      return success;
    } finally {
      if (visible) this.refreshing = false;
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
    this.sessionActionBusy = true;
    const ok = await AppServices.instance.tasks.patchSession(entry.deviceId, entry.session.id, patch);
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
          void this.applyBulkAction(action);
        },
      },
    });
  }

  private async applyBulkAction(action: string): Promise<void> {
    if (this.sessionActionBusy) return;
    this.sessionActionBusy = true;
    const keys = this.selectedEntryKeys.slice();
    const retained: string[] = [];
    let failed = 0;
    let skipped = 0;
    for (let i = 0; i < keys.length; i++) {
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
      if (!ok) {
        failed += 1;
        retained.push(keys[i]);
      }
    }
    this.sessionActionBusy = false;
    this.selectedEntryKeys = retained;
    this.bulkMode = retained.length > 0;
    if (failed > 0 || skipped > 0) {
      const parts: string[] = [];
      if (failed > 0) parts.push(`${failed} 个失败`);
      if (skipped > 0) parts.push(`${skipped} 个不适用`);
      promptAction.showToast({ message: `${parts.join('，')}，已保留选择` });
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
      const key = taskProjectKey(entry.deviceId, session.workingDir);
      let group = groups.get(key);
      if (group === undefined) {
        group = new TaskProjectGroup();
        group.key = key;
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
    if (this.sortMode !== 'default') {
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
    return `${prefix}:${entry.key}`;
  }

  private projectGroupRenderKey(group: TaskProjectGroup): string {
    // ForEach 会按 key 复用已有项目节点；成员签名确保跨端新建任务进入已有项目时真正重建。
    let key = `project:${group.key}`;
    for (let i = 0; i < group.entries.length; i++) {
      key += `:${group.entries[i].key}`;
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
          this.splitDivider()
          Column() {
            this.detailPane()
          }
          .layoutWeight(1)
          .height('100%')
        }
      }
      .width('100%')
      .height('100%')

      if (this.scopeMenuOpen) {
        this.scopeMenuLayer()
      }
      if (this.sortMenuOpen) {
        this.sortMenuLayer()
      }
      if (this.bulkMode) {
        this.bulkActionBar()
      }
    }
    .backgroundColor($r('app.color.bg_page'))
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .onAreaChange((oldArea: Area, newArea: Area) => {
      this.handleAreaChange(oldArea, newArea);
    })
  }

  @Builder
  taskListPane() {
    Column() {
      this.pageHeader()
      if (this.connectionStatus !== 'online') {
        this.connectionBanner()
      }
      this.taskListTabs()
      if (this.searchOpen) {
        this.taskSearchField()
      }
      Swiper(this.listTabSwiperController) {
        this.taskListTabPage('projects')
        this.taskListTabPage('dialogues')
        this.taskListTabPage('automations')
      }
      .id(LIST_TAB_SWIPER_ID)
      .index(this.initialListTabIndex)
      .indicator(false)
      .loop(false)
      .disableSwipe(true)
      .cachedCount(2)
      .duration(this.listTabIndicatorDuration())
      .curve(UI_CURVE_MOVE)
      .layoutWeight(1)
      .width('100%')
      .backgroundColor($r('app.color.bg_page'))
      .onAppear(() => this.handleListTabSwiperAppear())
    }
    .width(this.splitLayoutEnabled() ? this.listPaneWidth() : '100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder
  taskListTabPage(category: TaskListCategory) {
    Column() {
      if (this.scopedEntries().length === 0) {
        this.buildTaskListEmpty()
      } else {
        this.buildTaskListEntries(category)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  splitDivider() {
    Stack({ alignContent: Alignment.Center }) {
      Row()
        .width(1)
        .height('100%')
        .backgroundColor($r('app.color.border'))
      Stack({ alignContent: Alignment.Center }) {
        Row()
          .width(3)
          .height(20)
          .backgroundColor(this.dividerActive
            ? $r('app.color.accent')
            : $r('app.color.text_tertiary'))
          .borderRadius(UI_RADIUS_PILL)
      }
      .width(12)
      .height(44)
      .backgroundColor($r('app.color.task_list_group_surface'))
      .border({ width: 1, color: $r('app.color.border') })
      .borderRadius(UI_RADIUS_PILL)
    }
    .width(20)
    .height('100%')
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

      this.headerSymbolButton($r('sys.symbol.gearshape'), () => this.openSettings())
      this.headerSymbolButton($r('sys.symbol.magnifyingglass'), () => this.toggleSearch())
      this.refreshHeaderButton()
      this.headerSymbolButton($r('sys.symbol.plus'), () => this.openNewSession())
    }
    .width('100%')
    .height(60)
    .padding({ left: LIST_INSET, right: LIST_INSET, bottom: 12 })
    .border({ width: { bottom: 1 }, color: { bottom: $r('app.color.border') } })
  }

  @Builder
  headerSymbolButton(symbol: Resource, action: () => void) {
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
  taskListTabs() {
    Row({ space: 8 }) {
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('33.3333%')
          .height(34)
          .backgroundColor($r('app.color.task_list_group_surface'))
          .border({ width: 1, color: $r('app.color.border') })
          .borderRadius(UI_RADIUS_PILL)
          .translate({ x: this.listTabIndicatorTranslateX() })
          .animation({
            duration: this.listTabIndicatorDuration(),
            curve: UI_CURVE_MOVE,
            expectedFrameRateRange: LIST_TAB_FRAME_RATE,
          })
          .hitTestBehavior(HitTestMode.None)

        Row() {
          this.listTabButton('项目', 'projects')
          this.listTabButton('对话', 'dialogues')
          this.listTabButton('自动化', 'automations')
        }
        .width('100%')
        .height('100%')
      }
      .layoutWeight(1)
      .height(40)
      .padding(3)
      .backgroundColor($r('app.color.bg_chip'))
      .borderRadius(UI_RADIUS_PILL)

      Button() {
        SymbolGlyph($r('sys.symbol.slider_horizontal_2'))
          .fontSize(17)
          .fontColor([$r('app.color.text_secondary')])
      }
      .type(ButtonType.Circle)
      .width(36)
      .height(36)
      .padding(0)
      .backgroundColor($r('app.color.bg_chip'))
      .clickEffect(UI_ICON_CLICK_EFFECT)
      .accessibilityText('排序')
      .onClick(() => this.openSortMenu())
    }
    .width('100%')
    .height(56)
    .padding({ left: LIST_INSET, right: LIST_INSET, top: 8, bottom: 8 })
    .border({ width: { bottom: 1 }, color: { bottom: $r('app.color.border') } })
  }

  @Builder
  listTabButton(label: string, tab: TaskListCategory) {
    Button() {
      Text(label)
        .fontSize(14)
        .fontWeight(this.activeListTab === tab ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.activeListTab === tab
          ? $r('app.color.text_primary')
          : $r('app.color.text_secondary'))
    }
    .type(ButtonType.Normal)
    .layoutWeight(1)
    .height(34)
    .padding(0)
    .backgroundColor(Color.Transparent)
    .borderRadius(UI_RADIUS_PILL)
    .stateEffect(false)
    .onClick(() => this.selectListTab(tab))
  }

  @Builder
  taskSearchField() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(16)
        .fontColor([$r('app.color.text_secondary')])
      TextInput({ placeholder: '搜索标题、项目、模型或消息…', text: this.searchQuery })
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
        .onClick(() => {
          this.searchQuery = '';
          this.ensureWideSelection();
          this.persistPreferences();
        })
      }
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
  }

  @Builder
  buildTaskListEntries(category: TaskListCategory) {
    // 滑动只负责露出操作按钮；不要配置 actionAreaDistance / onAction，
    // 避免长距离滑动松手时直接置顶或归档，所有操作都必须由按钮点击触发。
    List() {
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
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .padding({ top: 8 })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
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

  private taskRightStatusKind(entry: TaskListEntry): string {
    const activity = AppServices.instance.tasks.getLiveActivity(entry.session.id);
    if (activity?.phase === 'error' && activity.attention) return 'error';
    if (AppServices.instance.interactions.getPending(entry.session.id).length > 0
      || activity?.phase === 'needs-interaction') return 'waiting';
    if (activity?.phase === 'running') return 'running';
    if (activity?.phase === 'completed' && activity.attention) return 'done';
    return 'time';
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
      this.collapseChevron(this.projectCollapsed(group.key))
    }
    .width('100%')
    .height(52)
    .padding({ left: LIST_INSET, right: LIST_INSET })
    .clickEffect(UI_LIST_CLICK_EFFECT)
    .onClick(() => this.toggleProject(group.key))
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
            this.projectExpandMenuOption()
          }
        }
        .width(184)
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
      .padding({ right: LIST_INSET })
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
      Text(this.allProjectsCollapsed() ? '展开项目' : '收起项目')
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
