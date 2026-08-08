/**
 * 任务聚合首页。
 *
 * 对齐 iOS：首页直接聚合所有可控制电脑的任务，标题下拉可按设备筛选并切换项目分组；
 * 页面存活期间订阅各设备的 sessions topic，列表数据始终来自被控端权威快照。
 */

import { display, router } from '@kit.ArkUI';
import { AppServices } from '../core/AppServices';
import { PresenceSnapshot, SESSIONS_TOPIC } from '../core/device-link/DlProtocol';
import { RemoteSession, readStr } from '../core/tasks/TaskModels';
import { TaskPageContent } from './TaskPage';
import {
  isWideTaskLayout,
  TASK_SPLIT_DEFAULT_RATIO,
  taskListPaneWidth,
  taskSplitRatioForDrag,
} from './TaskSplitLayout';
import {
  taskActivityAt,
  taskDisplayTitle,
  taskPreviewText,
  taskProjectKey,
  taskProjectName,
  taskRelativeTime,
  taskVisibleOnHome,
} from './TaskListPresentation';

const TASK_LIST_HORIZONTAL_INSET = 12;
const TASK_DAY_MS = 24 * 60 * 60 * 1000;

type TaskAgentFilter = 'all' | 'cc' | 'codex' | 'pi';
type TaskActivityFilter = 'all' | '1d' | '7d' | '30d';

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
  @State scopeMenuOpen: boolean = false;
  @State filterMenuOpen: boolean = false;
  @State projectFilterKeys: string[] = [];
  @State agentFilter: TaskAgentFilter = 'all';
  @State activityFilter: TaskActivityFilter = 'all';
  @State pinnedCollapsed: boolean = false;
  @State projectsSectionCollapsed: boolean = false;
  @State dialoguesCollapsed: boolean = false;
  @State collapsedProjectKeys: string[] = [];
  @State expandedProjectKeys: string[] = [];
  @State connectionStatus: string = 'connecting';
  @State now: number = Date.now();
  @State viewportWidth: number = 0;
  @State foldStatus: number = -1;
  @State listPaneRatio: number = TASK_SPLIT_DEFAULT_RATIO;
  @State dividerActive: boolean = false;

  private subscribedDeviceGenerations: Map<string, number> = new Map();
  private deviceOperationGenerations: Map<string, number> = new Map();
  private subscriptionRetryCounts: Map<string, number> = new Map();
  private subscriptionRetryTimers: Map<string, number> = new Map();
  private snapshotRetryCounts: Map<string, number> = new Map();
  private snapshotRetryTimers: Map<string, number> = new Map();
  private subscriptionGeneration: number = 0;
  private pageActive: boolean = false;
  private routeParamsInitialized: boolean = false;
  private unsubs: Array<() => void> = [];
  private clockTimer: number = -1;
  private dividerTouchStartX: number = 0;
  private dividerTouchStartRatio: number = TASK_SPLIT_DEFAULT_RATIO;
  private foldStatusListening: boolean = false;
  private foldStatusListener: (status: number) => void = (status: number): void => {
    this.foldStatus = status;
    this.ensureWideSelection();
  };

  aboutToAppear(): void {
    this.pageActive = true;
    this.subscriptionGeneration += 1;
    if (!this.routeParamsInitialized) {
      const params = (router.getParams() ?? {}) as Record<string, Object>;
      this.selectedDeviceId = readStr(params, 'deviceId');
      this.selectedSessionDeviceId = readStr(params, 'deviceId');
      this.selectedSessionId = readStr(params, 'sessionId');
      this.routeParamsInitialized = true;
    }
    this.connectionStatus = AppServices.instance.client.getStatus();
    this.observeFoldStatus();

    this.unsubs.push(AppServices.instance.tasks.onChanged(() => {
      this.refreshProjection();
      this.syncOpenableDevices();
    }));
    this.unsubs.push(AppServices.instance.onStatus((status: string) => {
      this.connectionStatus = status;
      // relay 状态切换后远端订阅均视为失效；设备操作仍串行等待旧链自行收尾。
      this.subscriptionGeneration += 1;
      this.subscribedDeviceGenerations.clear();
      this.clearAllRetries();
      if (status === 'online') {
        this.syncOpenableDevices();
      }
    }));

    this.refreshProjection();
    this.syncOpenableDevices();
    this.clockTimer = setInterval(() => {
      this.now = Date.now();
    }, 60_000);
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    this.subscriptionGeneration += 1;
    for (const unsubscribe of this.unsubs) {
      unsubscribe();
    }
    this.unsubs = [];
    if (this.clockTimer >= 0) {
      clearInterval(this.clockTimer);
      this.clockTimer = -1;
    }
    this.clearAllRetries();
    this.teardownAllSubscriptions();
    this.stopFoldStatusObservation();
    this.scopeMenuOpen = false;
    this.filterMenuOpen = false;
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
        if (!taskVisibleOnHome(session)) continue;
        const entry = new TaskListEntry();
        entry.key = `${device.deviceId}:${session.id}`;
        entry.deviceId = device.deviceId;
        entry.deviceName = device.deviceName;
        entry.session = session;
        next.push(entry);
      }
    }
    next.sort((a: TaskListEntry, b: TaskListEntry) => {
      const aTime = taskActivityAt(a.session);
      const bTime = taskActivityAt(b.session);
      if (aTime === bTime) return a.key < b.key ? -1 : 1;
      return aTime > bTime ? -1 : 1;
    });
    this.devices = devices;
    this.entries = next;
    this.ensureWideSelection();
  }

  private ensureWideSelection(): void {
    if (!isWideTaskLayout(this.viewportWidth, this.foldStatus)) return;
    const scoped = this.scopedEntries();
    for (let i = 0; i < scoped.length; i++) {
      if (scoped[i].deviceId === this.selectedSessionDeviceId
        && scoped[i].session.id === this.selectedSessionId) {
        return;
      }
    }
    if (scoped.length === 0) {
      this.selectedSessionDeviceId = '';
      this.selectedSessionId = '';
      return;
    }
    this.selectedSessionDeviceId = scoped[0].deviceId;
    this.selectedSessionId = scoped[0].session.id;
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

  private entrySelected(entry: TaskListEntry): boolean {
    return this.splitLayoutEnabled()
      && entry.deviceId === this.selectedSessionDeviceId
      && entry.session.id === this.selectedSessionId;
  }

  private selectSession(entry: TaskListEntry): void {
    this.selectedSessionDeviceId = entry.deviceId;
    this.selectedSessionId = entry.session.id;
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

  private syncOpenableDevices(): void {
    if (!this.pageActive || this.connectionStatus !== 'online') return;

    const devices = AppServices.instance.tasks.deviceList;
    const desiredDeviceIds: Set<string> = new Set();
    for (let i = 0; i < devices.length; i++) {
      if (this.deviceCanOpen(devices[i])) desiredDeviceIds.add(devices[i].deviceId);
      else this.clearDeviceRetries(devices[i].deviceId);
    }

    const staleSubscriptions: string[] = [];
    this.subscribedDeviceGenerations.forEach((generation: number, deviceId: string) => {
      if (!desiredDeviceIds.has(deviceId)) staleSubscriptions.push(deviceId);
    });
    for (let i = 0; i < staleSubscriptions.length; i++) {
      this.startUnsubscribe(staleSubscriptions[i]);
    }

    for (let i = 0; i < devices.length; i++) {
      const deviceId = devices[i].deviceId;
      if (!desiredDeviceIds.has(deviceId)
        || this.subscribedDeviceGenerations.has(deviceId)
        || this.deviceOperationGenerations.has(deviceId)
        || this.subscriptionRetryTimers.has(deviceId)) {
        continue;
      }
      const generation = this.subscriptionGeneration;
      this.deviceOperationGenerations.set(deviceId, generation);
      void this.subscribeDevice(deviceId, generation);
    }
  }

  private async subscribeDevice(deviceId: string, generation: number): Promise<void> {
    let subscribed = false;
    try {
      await AppServices.instance.openLink(deviceId);
      if (!this.subscriptionStillNeeded(deviceId, generation)) {
        this.finishDeviceOperation(deviceId, generation);
        return;
      }
      await AppServices.instance.client.subscribe(deviceId, [SESSIONS_TOPIC]);
      subscribed = true;
      if (!this.subscriptionStillNeeded(deviceId, generation)) {
        await this.unsubscribeDevice(deviceId);
        this.finishDeviceOperation(deviceId, generation);
        return;
      }

      this.subscribedDeviceGenerations.set(deviceId, generation);
      this.clearSubscriptionRetry(deviceId);
      this.finishDeviceOperation(deviceId, generation);
      const loaded = await AppServices.instance.tasks.loadSessions(deviceId);
      if (!loaded && this.snapshotStillNeeded(deviceId, generation)) {
        this.scheduleSnapshotRetry(deviceId, generation);
      } else if (loaded) {
        this.clearSnapshotRetry(deviceId);
      }
    } catch (e) {
      if (subscribed) await this.unsubscribeDevice(deviceId);
      if (this.subscriptionStillNeeded(deviceId, generation)) {
        // 订阅失败时也拉一次快照；operation 标记防止 Store notify 触发紧密重试。
        await AppServices.instance.tasks.loadSessions(deviceId);
        if (this.subscriptionStillNeeded(deviceId, generation)) {
          this.scheduleSubscriptionRetry(deviceId, generation);
        }
      }
      this.finishDeviceOperation(deviceId, generation);
    }
  }

  private finishDeviceOperation(deviceId: string, generation: number): void {
    if (this.deviceOperationGenerations.get(deviceId) === generation) {
      this.deviceOperationGenerations.delete(deviceId);
    }
    if (this.pageActive) this.syncOpenableDevices();
  }

  private teardownAllSubscriptions(): void {
    const deviceIds: string[] = [];
    this.subscribedDeviceGenerations.forEach((generation: number, deviceId: string) => {
      deviceIds.push(deviceId);
    });
    for (let i = 0; i < deviceIds.length; i++) this.startUnsubscribe(deviceIds[i]);
  }

  private startUnsubscribe(deviceId: string): void {
    this.subscribedDeviceGenerations.delete(deviceId);
    this.clearDeviceRetries(deviceId);
    if (this.deviceOperationGenerations.has(deviceId)) return;
    const generation = this.subscriptionGeneration;
    this.deviceOperationGenerations.set(deviceId, generation);
    void this.runUnsubscribe(deviceId, generation);
  }

  private async runUnsubscribe(deviceId: string, generation: number): Promise<void> {
    await this.unsubscribeDevice(deviceId);
    this.finishDeviceOperation(deviceId, generation);
  }

  private subscriptionStillNeeded(deviceId: string, generation: number): boolean {
    if (!this.pageActive || generation !== this.subscriptionGeneration
      || this.connectionStatus !== 'online') {
      return false;
    }
    const devices = AppServices.instance.tasks.deviceList;
    for (let i = 0; i < devices.length; i++) {
      if (devices[i].deviceId === deviceId) return this.deviceCanOpen(devices[i]);
    }
    return false;
  }

  private snapshotStillNeeded(deviceId: string, generation: number): boolean {
    return this.subscriptionStillNeeded(deviceId, generation)
      && this.subscribedDeviceGenerations.get(deviceId) === generation;
  }

  private retryDelay(retryCount: number): number {
    return Math.min(30_000, 2_000 * Math.pow(2, Math.min(retryCount, 4)));
  }

  private scheduleSubscriptionRetry(deviceId: string, generation: number): void {
    if (this.subscriptionRetryTimers.has(deviceId)) return;
    const retryCount = this.subscriptionRetryCounts.get(deviceId) ?? 0;
    this.subscriptionRetryCounts.set(deviceId, retryCount + 1);
    const timer = setTimeout(() => {
      this.subscriptionRetryTimers.delete(deviceId);
      if (this.subscriptionStillNeeded(deviceId, generation)) {
        this.syncOpenableDevices();
      } else if (this.pageActive) {
        // generation 已变化时立即让当前页面重新收敛，不能被旧 timer 卡住。
        this.syncOpenableDevices();
      }
    }, this.retryDelay(retryCount));
    this.subscriptionRetryTimers.set(deviceId, timer);
  }

  private scheduleSnapshotRetry(deviceId: string, generation: number): void {
    if (this.snapshotRetryTimers.has(deviceId)) return;
    const retryCount = this.snapshotRetryCounts.get(deviceId) ?? 0;
    this.snapshotRetryCounts.set(deviceId, retryCount + 1);
    const timer = setTimeout(() => {
      this.snapshotRetryTimers.delete(deviceId);
      if (this.snapshotStillNeeded(deviceId, generation)) {
        void this.retrySnapshot(deviceId, generation);
      }
    }, this.retryDelay(retryCount));
    this.snapshotRetryTimers.set(deviceId, timer);
  }

  private async retrySnapshot(deviceId: string, generation: number): Promise<void> {
    const loaded = await AppServices.instance.tasks.loadSessions(deviceId);
    if (loaded) {
      this.clearSnapshotRetry(deviceId);
    } else if (this.snapshotStillNeeded(deviceId, generation)) {
      this.scheduleSnapshotRetry(deviceId, generation);
    }
  }

  private clearSubscriptionRetry(deviceId: string): void {
    const timer = this.subscriptionRetryTimers.get(deviceId);
    if (timer !== undefined) clearTimeout(timer);
    this.subscriptionRetryTimers.delete(deviceId);
    this.subscriptionRetryCounts.delete(deviceId);
  }

  private clearSnapshotRetry(deviceId: string): void {
    const timer = this.snapshotRetryTimers.get(deviceId);
    if (timer !== undefined) clearTimeout(timer);
    this.snapshotRetryTimers.delete(deviceId);
    this.snapshotRetryCounts.delete(deviceId);
  }

  private clearDeviceRetries(deviceId: string): void {
    this.clearSubscriptionRetry(deviceId);
    this.clearSnapshotRetry(deviceId);
  }

  private clearAllRetries(): void {
    this.subscriptionRetryTimers.forEach((timer: number) => clearTimeout(timer));
    this.snapshotRetryTimers.forEach((timer: number) => clearTimeout(timer));
    this.subscriptionRetryTimers.clear();
    this.subscriptionRetryCounts.clear();
    this.snapshotRetryTimers.clear();
    this.snapshotRetryCounts.clear();
  }

  private async unsubscribeDevice(deviceId: string): Promise<void> {
    try {
      await AppServices.instance.client.unsubscribe(deviceId, [SESSIONS_TOPIC]);
    } catch (e) {
      // teardown 与单设备状态收敛均为 best-effort，不能关闭共享 relay。
    }
  }

  private deviceCanOpen(device: PresenceSnapshot): boolean {
    return device.online && device.remoteControlEnabled;
  }

  private openSession(entry: TaskListEntry): void {
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

  private openDeviceScopeMenu(): void {
    this.filterMenuOpen = false;
    this.scopeMenuOpen = true;
  }

  private openFilterMenu(): void {
    this.scopeMenuOpen = false;
    this.filterMenuOpen = !this.filterMenuOpen;
  }

  private selectDevice(deviceId: string): void {
    this.selectedDeviceId = deviceId;
    this.projectFilterKeys = [];
    this.scopeMenuOpen = false;
    this.filterMenuOpen = false;
    this.ensureWideSelection();
  }

  private selectedDeviceLabel(): string {
    if (this.selectedDeviceId.length === 0) return '所有任务';
    for (let i = 0; i < this.devices.length; i++) {
      if (this.devices[i].deviceId === this.selectedDeviceId) {
        return this.devices[i].deviceName;
      }
    }
    return AppServices.instance.tasks.getDeviceName(this.selectedDeviceId);
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
    const activityDays = this.activityFilterDays();
    for (let i = 0; i < source.length; i++) {
      const entry = source[i];
      const session = entry.session;
      const isDialogue = session.workspaceKind === 'dialogue' || session.workingDir.length === 0;
      if (this.projectFilterKeys.length > 0) {
        if (isDialogue || this.projectFilterKeys.indexOf(taskProjectKey(entry.deviceId, session.workingDir)) < 0) {
          continue;
        }
      }
      if (this.agentFilter !== 'all' && session.agentKind !== this.agentFilter) continue;
      if (activityDays > 0) {
        const activityAt = Date.parse(taskActivityAt(session));
        if (Number.isFinite(activityAt) && this.now - activityAt > activityDays * TASK_DAY_MS) continue;
      }
      out.push(entry);
    }
    return out;
  }

  private activityFilterDays(): number {
    if (this.activityFilter === '1d') return 1;
    if (this.activityFilter === '7d') return 7;
    if (this.activityFilter === '30d') return 30;
    return 0;
  }

  private taskFilterActive(): boolean {
    return this.projectFilterKeys.length > 0
      || this.agentFilter !== 'all'
      || this.activityFilter !== 'all';
  }

  private projectFilterGroups(): TaskProjectGroup[] {
    return this.projectGroupsFrom(this.deviceScopedEntries());
  }

  private setProjectFilterAll(): void {
    this.projectFilterKeys = [];
    this.ensureWideSelection();
  }

  private toggleProjectFilter(key: string): void {
    if (this.projectFilterKeys.length === 0) {
      this.projectFilterKeys = [key];
    } else if (this.projectFilterKeys.indexOf(key) >= 0) {
      this.projectFilterKeys = this.projectFilterKeys.filter((value: string) => value !== key);
    } else {
      this.projectFilterKeys = this.projectFilterKeys.concat([key]);
    }
    this.ensureWideSelection();
  }

  private setAgentFilter(filter: TaskAgentFilter): void {
    this.agentFilter = filter;
    this.filterMenuOpen = false;
    this.ensureWideSelection();
  }

  private setActivityFilter(filter: TaskActivityFilter): void {
    this.activityFilter = filter;
    this.filterMenuOpen = false;
    this.ensureWideSelection();
  }

  private clearTaskFilters(): void {
    this.projectFilterKeys = [];
    this.agentFilter = 'all';
    this.activityFilter = 'all';
    this.filterMenuOpen = false;
    this.ensureWideSelection();
  }

  private projectFilterLabel(): string {
    if (this.projectFilterKeys.length === 0) return '全部项目';
    return `${this.projectFilterKeys.length} 个项目`;
  }

  private agentFilterLabel(): string {
    if (this.agentFilter === 'cc') return 'Claude Code';
    if (this.agentFilter === 'codex') return 'Codex';
    if (this.agentFilter === 'pi') return 'Pi';
    return '全部代理';
  }

  private activityFilterLabel(): string {
    if (this.activityFilter === '1d') return '最近一天';
    if (this.activityFilter === '7d') return '最近七天';
    if (this.activityFilter === '30d') return '最近三十天';
    return '全部时间';
  }

  private pinnedEntries(): TaskListEntry[] {
    const out: TaskListEntry[] = [];
    const scoped = this.scopedEntries();
    for (let i = 0; i < scoped.length; i++) {
      if (scoped[i].session.pinnedAt.length > 0) out.push(scoped[i]);
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
      // dialogue 会话即使有自动分配的 workingDir，也必须留在「对话」区。
      if (session.workspaceKind === 'dialogue' || session.workingDir.length === 0) continue;
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
    out.sort((a: TaskProjectGroup, b: TaskProjectGroup) => {
      if (a.latestActivityAt === b.latestActivityAt) return a.key < b.key ? -1 : 1;
      return a.latestActivityAt > b.latestActivityAt ? -1 : 1;
    });
    return out;
  }

  private dialogueEntries(): TaskListEntry[] {
    const out: TaskListEntry[] = [];
    const entries = this.regularEntries();
    for (let i = 0; i < entries.length; i++) {
      const session = entries[i].session;
      if (session.workspaceKind === 'dialogue' || session.workingDir.length === 0) {
        out.push(entries[i]);
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
      this.collapsedProjectKeys = [];
      return;
    }
    const keys: string[] = [];
    for (let i = 0; i < groups.length; i++) keys.push(groups[i].key);
    this.collapsedProjectKeys = keys;
  }

  private projectCollapsed(key: string): boolean {
    return this.collapsedProjectKeys.indexOf(key) >= 0;
  }

  private toggleProject(key: string): void {
    const index = this.collapsedProjectKeys.indexOf(key);
    if (index >= 0) {
      this.collapsedProjectKeys = this.collapsedProjectKeys.filter((value: string) => value !== key);
    } else {
      this.collapsedProjectKeys = this.collapsedProjectKeys.concat([key]);
    }
  }

  private projectFullyExpanded(key: string): boolean {
    return this.expandedProjectKeys.indexOf(key) >= 0;
  }

  private visibleProjectEntries(group: TaskProjectGroup): TaskListEntry[] {
    if (this.projectFullyExpanded(group.key) || group.entries.length <= 5) return group.entries;
    return group.entries.slice(0, 5);
  }

  private toggleProjectExpanded(key: string): void {
    if (this.projectFullyExpanded(key)) {
      this.expandedProjectKeys = this.expandedProjectKeys.filter((value: string) => value !== key);
    } else {
      this.expandedProjectKeys = this.expandedProjectKeys.concat([key]);
    }
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
    if (this.taskFilterActive()) return '没有符合条件的任务';
    if (this.devices.length === 0) return '还没有可控制的电脑';
    if (this.availableDeviceCount() === 0) return '电脑当前不可用';
    return '暂无任务';
  }

  private emptyCopy(): string {
    if (this.connectionStatus === 'connecting') return '连接后将自动同步任务';
    if (this.taskFilterActive()) return '可以调整项目、代理或最近活动筛选';
    if (this.devices.length === 0) return '请确认电脑端 Cindy 已登录并开启远程控制';
    if (this.availableDeviceCount() === 0) return '请将电脑上线并开启远程控制';
    if (this.selectedDeviceId.length > 0) return '这台电脑当前没有任务';
    return '新任务会显示在这里';
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
      if (this.filterMenuOpen) {
        this.filterMenuLayer()
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
      Stack({ alignContent: Alignment.BottomEnd }) {
        this.taskList()
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width(this.splitLayoutEnabled() ? this.listPaneWidth() : '100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
    .border({
      width: { right: this.splitLayoutEnabled() ? 1 : 0 },
      color: { right: $r('app.color.border') },
    })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder
  splitDivider() {
    Stack({ alignContent: Alignment.Center }) {
      Row()
        .width(5)
        .height(23)
        .backgroundColor(Color.Transparent)
        .border({
          width: 1,
          color: this.dividerActive
            ? $r('app.color.accent')
            : $r('app.color.text_tertiary'),
        })
        .borderRadius(3)
        .opacity(this.dividerActive ? 0.95 : 0.55)
        .translate({ x: -10 })
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
      ForEach([this.selectedTaskKey()], (key: string) => {
        TaskPageContent({
          paneDeviceId: this.selectedSessionDeviceId,
          paneSessionId: this.selectedSessionId,
        })
      }, (key: string) => key)
    }
  }

  @Builder
  emptyDetailPane() {
    Column() {
      Text('选择一个任务')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor($r('app.color.bg_page'))
  }

  @Builder
  pageHeader() {
    Row() {
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
      .height(48)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        this.openDeviceScopeMenu();
      })

      Button() {
        Text('C')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
      }
      .type(ButtonType.Circle)
      .width(45)
      .height(45)
      .padding(0)
      .backgroundColor($r('app.color.bg_chip'))
      .onClick(() => this.openSettings())
    }
    .width('100%')
    .height(60)
    .padding({ left: 20, right: 20, bottom: 12 })
    .border({ width: { bottom: 1 }, color: { bottom: $r('app.color.border') } })
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
    .height(38)
    .padding({ left: 20, right: 20 })
    .border({ width: { bottom: 1 }, color: { bottom: $r('app.color.border') } })
  }

  @Builder
  taskList() {
    if (this.scopedEntries().length === 0) {
      Column({ space: 8 }) {
        Text(this.emptyTitle())
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
        Text(this.emptyCopy())
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .textAlign(TextAlign.Center)
        if (this.taskFilterActive()) {
          Button() {
            Text('清除筛选')
              .fontSize(13)
              .fontColor($r('app.color.text_primary'))
          }
          .type(ButtonType.Normal)
          .height(36)
          .padding({ left: 16, right: 16 })
          .backgroundColor($r('app.color.bg_chip'))
          .borderRadius(18)
          .onClick(() => this.clearTaskFilters())
        }
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .padding({ left: 32, right: 32, bottom: 80 })
    } else {
      List() {
        if (this.pinnedEntries().length > 0) {
          ListItem() {
            this.pinnedHeader(this.pinnedEntries().length)
          }
          if (!this.pinnedCollapsed) {
            ForEach(this.pinnedEntries(), (entry: TaskListEntry) => {
              ListItem() {
                this.sessionCard(entry)
              }
            }, (entry: TaskListEntry) => `pinned:${entry.key}`)
          }
        }

        if (this.projectGroups().length > 0
          || this.projectFilterGroups().length > 0
          || this.taskFilterActive()) {
          ListItem() {
            this.projectSectionHeader()
          }
          if (!this.projectsSectionCollapsed) {
            ForEach(this.projectGroups(), (group: TaskProjectGroup) => {
              ListItem() {
                this.projectGroup(group)
              }
            }, (group: TaskProjectGroup) => `project:${group.key}`)
          }
        }

        if (this.dialogueEntries().length > 0) {
          ListItem() {
            this.dialogueSectionHeader(this.dialogueEntries().length)
          }
          if (!this.dialoguesCollapsed) {
            ForEach(this.dialogueEntries(), (entry: TaskListEntry) => {
              ListItem() {
                this.sessionCard(entry)
              }
            }, (entry: TaskListEntry) => `dialogue:${entry.key}`)
          }
        }

        // 作为真实列表项保留 FAB 避让区，避免 List padding 把屏底附近的后续行判成不可见。
        ListItem() {
          Row()
            .width('100%')
            .height(112)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
      .padding({ top: 10 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
  }

  @Builder
  projectSectionHeader() {
    Row({ space: 6 }) {
      Row({ space: 6 }) {
        SymbolGlyph(this.projectsSectionCollapsed
          ? $r('sys.symbol.chevron_right')
          : $r('sys.symbol.chevron_down'))
          .fontSize(13)
          .fontColor([$r('app.color.text_secondary')])
        Text('项目')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .onClick(() => {
        this.projectsSectionCollapsed = !this.projectsSectionCollapsed;
      })

      Button() {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.chevron_up'))
            .fontSize(9)
            .fontColor([$r('app.color.text_secondary')])
            .translate({ y: -4 })
          SymbolGlyph($r('sys.symbol.chevron_down'))
            .fontSize(9)
            .fontColor([$r('app.color.text_secondary')])
            .translate({ y: 4 })
        }
        .width(16)
        .height(18)
      }
      .type(ButtonType.Normal)
      .width(28)
      .height(28)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .onClick(() => this.toggleAllProjects())

      Button() {
        SymbolGlyph($r('sys.symbol.slider_horizontal_2'))
          .fontSize(15)
          .fontColor([this.taskFilterActive()
            ? $r('app.color.accent')
            : $r('app.color.text_secondary')])
      }
      .type(ButtonType.Normal)
      .width(28)
      .height(28)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .onClick(() => this.openFilterMenu())
    }
    .width('100%')
    .height(42)
    .padding({ left: TASK_LIST_HORIZONTAL_INSET, right: TASK_LIST_HORIZONTAL_INSET })
  }

  @Builder
  dialogueSectionHeader(count: number) {
    Row({ space: 6 }) {
      Row({ space: 6 }) {
        SymbolGlyph(this.dialoguesCollapsed
          ? $r('sys.symbol.chevron_right')
          : $r('sys.symbol.chevron_down'))
          .fontSize(13)
          .fontColor([$r('app.color.text_secondary')])
        Text('对话')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_secondary'))
      }
      .layoutWeight(1)
      .onClick(() => {
        this.dialoguesCollapsed = !this.dialoguesCollapsed;
      })
      Text(`${count}`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .height(42)
    .padding({ left: TASK_LIST_HORIZONTAL_INSET, right: TASK_LIST_HORIZONTAL_INSET })
  }

  @Builder
  pinnedHeader(count: number) {
    Row({ space: 8 }) {
      SymbolGlyph(this.pinnedCollapsed
        ? $r('sys.symbol.chevron_right')
        : $r('sys.symbol.chevron_down'))
        .fontSize(15)
        .fontColor([$r('app.color.text_secondary')])
        .width(20)
      SymbolGlyph($r('sys.symbol.pin'))
        .fontSize(17)
        .fontColor([$r('app.color.text_secondary')])
      Text('置顶')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Text(`${count}`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .height(50)
    .padding({ left: TASK_LIST_HORIZONTAL_INSET, right: TASK_LIST_HORIZONTAL_INSET })
    .onClick(() => {
      this.pinnedCollapsed = !this.pinnedCollapsed;
    })
  }

  @Builder
  sessionCard(entry: TaskListEntry) {
    Row({ space: 10 }) {
      this.agentMark(entry.session.agentKind)
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
          Text(taskRelativeTime(taskActivityAt(entry.session), this.now))
            .fontSize(11)
            .lineHeight(16)
            .fontColor($r('app.color.text_secondary'))
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
    .height(taskPreviewText(entry.session.preview).length > 0 ? 78 : 60)
    .padding({ left: 18, right: 18, top: 10, bottom: 10 })
    .margin({ left: TASK_LIST_HORIZONTAL_INSET, right: TASK_LIST_HORIZONTAL_INSET, bottom: 10 })
    .backgroundColor(this.entrySelected(entry)
      ? $r('app.color.bg_chip')
      : $r('app.color.task_list_row_surface'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(8)
    .onClick(() => this.openSession(entry))
  }

  @Builder
  projectGroup(group: TaskProjectGroup) {
    Column() {
      Row({ space: 8 }) {
        SymbolGlyph(this.projectCollapsed(group.key)
          ? $r('sys.symbol.chevron_right')
          : $r('sys.symbol.chevron_down'))
          .fontSize(15)
          .fontColor([$r('app.color.text_secondary')])
          .width(18)
        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize(19)
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
      }
      .width('100%')
      .height(56)
      .padding({ left: 14, right: 16 })
      .onClick(() => this.toggleProject(group.key))

      if (!this.projectCollapsed(group.key)) {
        ForEach(this.visibleProjectEntries(group), (entry: TaskListEntry, index?: number) => {
          this.projectSessionRow(entry, (index ?? 0) > 0)
        }, (entry: TaskListEntry) => `project-session:${entry.key}`)
        if (group.entries.length > 5) {
          this.projectViewAllRow(group)
        }
      }
    }
    .width('auto')
    .margin({ left: TASK_LIST_HORIZONTAL_INSET, right: TASK_LIST_HORIZONTAL_INSET, bottom: 10 })
    .backgroundColor($r('app.color.task_list_group_surface'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(8)
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
        .fontSize(14)
        .fontColor([$r('app.color.text_tertiary')])
    }
    .width('100%')
    .height(46)
    .padding({ left: 62, right: 18 })
    .border({ width: { top: 1 }, color: { top: $r('app.color.border') } })
    .onClick(() => this.toggleProjectExpanded(group.key))
  }

  @Builder
  projectSessionRow(entry: TaskListEntry, showDivider: boolean) {
    Row({ space: 10 }) {
      this.agentMark(entry.session.agentKind)
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
          Text(taskRelativeTime(taskActivityAt(entry.session), this.now))
            .fontSize(11)
            .lineHeight(16)
            .fontColor($r('app.color.text_secondary'))
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
    .width('100%')
    .height(taskPreviewText(entry.session.preview).length > 0 ? 78 : 60)
    .padding({ left: 30, right: 18, top: 10, bottom: 10 })
    .backgroundColor(this.entrySelected(entry)
      ? $r('app.color.bg_chip')
      : Color.Transparent)
    .border({
      width: { top: showDivider ? 1 : 0 },
      color: { top: $r('app.color.border') },
    })
    .onClick(() => this.openSession(entry))
  }

  @Builder
  agentMark(agentKind: string) {
    Stack({ alignContent: Alignment.Center }) {
      Text(this.agentMarkText(agentKind))
        .fontSize(agentKind === 'pi' ? 12 : 9)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
    }
    .width(22)
    .height(22)
    .backgroundColor($r('app.color.bg_chip'))
    .border({ width: 1, color: $r('app.color.border') })
    .borderRadius(6)
  }

  private agentMarkText(agentKind: string): string {
    if (agentKind === 'cc') return 'CC';
    if (agentKind === 'codex') return 'CX';
    if (agentKind === 'pi') return 'Pi';
    return 'AI';
  }

  @Builder
  filterMenuLayer() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.task_list_overlay'))
      .onClick(() => {
        this.filterMenuOpen = false;
      })

      Column() {
        Scroll() {
          Column() {
            Text('筛选任务')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
              .padding({ left: 10, right: 10, top: 8, bottom: 6 })

            Row({ space: 8 }) {
              Text('项目')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .layoutWeight(1)
              Text(this.projectFilterLabel())
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })

            this.taskFilterOption('全部项目', this.projectFilterKeys.length === 0, () => {
              this.setProjectFilterAll();
            })
            ForEach(this.projectFilterGroups(), (group: TaskProjectGroup) => {
              this.taskFilterProjectOption(group)
            }, (group: TaskProjectGroup) => `filter-project:${group.key}`)

            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.border'))
              .margin({ top: 6, bottom: 6 })

            Row({ space: 8 }) {
              Text('代理')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .layoutWeight(1)
              Text(this.agentFilterLabel())
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            this.taskFilterOption('全部代理', this.agentFilter === 'all', () => {
              this.setAgentFilter('all');
            })
            this.taskFilterOption('Claude Code', this.agentFilter === 'cc', () => {
              this.setAgentFilter('cc');
            })
            this.taskFilterOption('Codex', this.agentFilter === 'codex', () => {
              this.setAgentFilter('codex');
            })
            this.taskFilterOption('Pi', this.agentFilter === 'pi', () => {
              this.setAgentFilter('pi');
            })

            Divider()
              .strokeWidth(0.5)
              .color($r('app.color.border'))
              .margin({ top: 6, bottom: 6 })

            Row({ space: 8 }) {
              Text('最近活动')
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
                .layoutWeight(1)
              Text(this.activityFilterLabel())
                .fontSize(12)
                .fontColor($r('app.color.text_tertiary'))
            }
            .width('100%')
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            this.taskFilterOption('全部时间', this.activityFilter === 'all', () => {
              this.setActivityFilter('all');
            })
            this.taskFilterOption('最近一天', this.activityFilter === '1d', () => {
              this.setActivityFilter('1d');
            })
            this.taskFilterOption('最近七天', this.activityFilter === '7d', () => {
              this.setActivityFilter('7d');
            })
            this.taskFilterOption('最近三十天', this.activityFilter === '30d', () => {
              this.setActivityFilter('30d');
            })
          }
          .width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: 520 })
        .scrollBar(BarState.Off)
      }
      .width(280)
      .padding(8)
      .margin({ left: 20, top: 104 })
      .backgroundColor($r('app.color.task_list_menu_surface'))
      .border({ width: 1, color: $r('app.color.border') })
      .borderRadius(8)
      .onClick(() => {
        // 截住面板区域点击，避免穿透到遮罩。
      })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  taskFilterOption(label: string, selected: boolean, action: () => void) {
    Row({ space: 10 }) {
      this.scopeMenuCheck(selected)
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
    }
    .width('100%')
    .height(44)
    .padding({ left: 10, right: 12 })
    .backgroundColor(selected ? $r('app.color.bg_chip') : Color.Transparent)
    .borderRadius(6)
    .onClick(action)
  }

  @Builder
  taskFilterProjectOption(group: TaskProjectGroup) {
    Row({ space: 10 }) {
      this.scopeMenuCheck(this.projectFilterKeys.length === 0
        || this.projectFilterKeys.indexOf(group.key) >= 0)
      SymbolGlyph($r('sys.symbol.folder'))
        .fontSize(17)
        .fontColor([$r('app.color.text_secondary')])
        .width(22)
      Text(group.title)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(`${group.entries.length}`)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width('100%')
    .height(44)
    .padding({ left: 10, right: 12 })
    .backgroundColor(this.projectFilterKeys.length === 0
      || this.projectFilterKeys.indexOf(group.key) >= 0
      ? $r('app.color.bg_chip')
      : Color.Transparent)
    .borderRadius(6)
    .onClick(() => this.toggleProjectFilter(group.key))
  }

  @Builder
  scopeMenuLayer() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.task_list_overlay'))
      .onClick(() => {
        this.scopeMenuOpen = false;
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
      .margin({ left: 20, top: 52 })
      .backgroundColor($r('app.color.task_list_menu_surface'))
      .border({ width: 1, color: $r('app.color.border') })
      .borderRadius(8)
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
      this.scopeMenuCheck(this.selectedDeviceId.length === 0)
      SymbolGlyph($r('sys.symbol.rectangle_stack'))
        .fontSize(18)
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
    .borderRadius(6)
    .onClick(() => this.selectDevice(''))
  }

  @Builder
  scopeMenuDeviceRow(device: PresenceSnapshot) {
    Row({ space: 10 }) {
      this.scopeMenuCheck(this.selectedDeviceId === device.deviceId)
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.rectangle_stack'))
          .fontSize(18)
          .fontColor([$r('app.color.text_secondary')])
        Circle()
          .width(7)
          .height(7)
          .fill(this.deviceCanOpen(device)
            ? $r('app.color.success')
            : $r('app.color.text_tertiary'))
          .margin({ left: 16, top: 16 })
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
    .borderRadius(6)
    .onClick(() => this.selectDevice(device.deviceId))
  }

  @Builder
  scopeMenuCheck(selected: boolean) {
    Stack({ alignContent: Alignment.Center }) {
      if (selected) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(15)
          .fontColor([$r('app.color.text_primary')])
      }
    }
    .width(18)
    .height(18)
  }
}
