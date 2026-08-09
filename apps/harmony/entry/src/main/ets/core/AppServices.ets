/**
 * 应用服务组装（单例）。
 *
 * 把 AuthStore / DlClient / TaskStore / MessageStore 接成一条管线：
 * - DlClient 每次连接前经 AuthStore 取新鲜 access token；
 * - presence-changed → TaskStore（设备列表）；
 * - push → 按 channel 分发到 TaskStore（sessions 列表）/ MessageStore（单会话流）；
 * - 连接状态 → UI 订阅（首页连接 banner）。
 *
 * 页面（EntryAbility onCreate）先调 init(context) 再使用。
 */

import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppConfig } from '../AppConfig';
import { HarmonyWsAdapter } from '../network/HarmonyWsAdapter';
import { HarmonyHttp } from '../network/HarmonyHttp';
import { AuthStore } from './auth/AuthStore';
import { DlClient, DlClientOptions, DlEvents, DlOpenLinkOptions } from './device-link/DlClient';
import {
  HelloPayload, HelloAckPayload, PresenceSnapshot, DlChannels, SESSIONS_TOPIC,
} from './device-link/DlProtocol';
import { TaskStore } from './tasks/TaskStore';
import { DeviceView, parseDeviceView, readStr } from './tasks/TaskModels';
import { MessageStore } from './messages/MessageStore';
import { InteractionStore } from './interactions/InteractionStore';
import { GoalStore } from './goals/GoalStore';
import { InputQueueStore } from './messages/InputQueueStore';
import { ComposerDraftStore } from './messages/ComposerDraftStore';
import { TaskListPreferenceStore } from './tasks/TaskListPreferenceStore';

const DOMAIN = 0x0000;
const TAG = 'CindyApp';

/** 简单延时。 */
function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });
}

export class AppServices {
  static readonly instance: AppServices = new AppServices();

  readonly auth: AuthStore = new AuthStore();
  readonly tasks: TaskStore = new TaskStore();
  readonly messages: MessageStore = new MessageStore();
  readonly inputQueue: InputQueueStore = new InputQueueStore();
  readonly composerDrafts: ComposerDraftStore = new ComposerDraftStore();
  readonly taskListPreferences: TaskListPreferenceStore = new TaskListPreferenceStore();
  readonly interactions: InteractionStore = new InteractionStore();
  readonly goals: GoalStore = new GoalStore();
  readonly client: DlClient;
  private readonly http: HarmonyHttp = new HarmonyHttp();
  private statusListeners: Array<(status: string) => void> = [];
  /** 已建立控制链路的设备（openLink 幂等去重）。 */
  private linkedDevices: Set<string> = new Set();
  /** 应用级 sessions topic 订阅；不能绑在任务列表页面，否则离开页面就漏实时更新。 */
  private sessionSubscribedDevices: Set<string> = new Set();
  private sessionSubscriptionOperations: Set<string> = new Set();
  private sessionSubscriptionRetryCounts: Map<string, number> = new Map();
  private sessionSubscriptionRetryTimers: Map<string, number> = new Map();
  private sessionSnapshotRetryCounts: Map<string, number> = new Map();
  private sessionSnapshotRetryTimers: Map<string, number> = new Map();
  private sessionSubscriptionGeneration: number = 0;

  private constructor() {
    const opts = new DlClientOptions();
    opts.getWsUrl = () => AppConfig.deviceLinkWsUrl;
    opts.getToken = () => this.auth.getAccessToken();
    opts.getHello = () => this.buildHello();
    opts.createWs = () => new HarmonyWsAdapter();
    opts.events = this.buildEvents();
    this.client = new DlClient(opts);
    this.tasks.attach(this.client);
    this.tasks.onChanged(() => {
      this.syncSessionSubscriptions();
    });
    this.messages.attach(this.client);
    this.inputQueue.attach(this.client);
    this.interactions.attach(this.client);
    this.goals.attach(this.client);
    this.messages.setLinkOpener((deviceId: string) => this.openLink(deviceId));
    this.inputQueue.setLinkOpener((deviceId: string) => this.openLink(deviceId));
    this.goals.setLinkOpener((deviceId: string) => this.openLink(deviceId));
  }

  /**
   * 建立控制链路（link-open → link-accept），幂等：同一设备已建立则跳过。
   * 所有跨设备 invoke（订阅 / 历史 / 发送 / 交互）都依赖它。
   * 连接未就绪时先等待（最多 5s）；link-accept 8s 超时不阻塞后续（失败走重试）。
   */
  async openLink(deviceId: string): Promise<void> {
    if (this.linkedDevices.has(deviceId)) {
      return;
    }
    await this.client.waitUntilOnline(5000);
    const opts = new DlOpenLinkOptions();
    opts.controllerName = 'Cindy Harmony';
    opts.appVersion = AppConfig.appVersion;
    opts.capabilities = [];
    try {
      await Promise.race([
        this.client.openLink(deviceId, opts),
        delay(8000).then(() => {
          throw new Error('Device Link open-link timeout');
        }),
      ]);
      // 只有真实 link-accept 才标记；超时必须允许下一次调用重试。
      this.linkedDevices.add(deviceId);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'openLink failed: %{public}s', JSON.stringify(e));
    }
  }

  async init(context: common.Context): Promise<void> {
    await Promise.all([
      this.auth.init(context),
      this.composerDrafts.init(context),
      this.taskListPreferences.init(context),
    ]);
  }

  /** 连接状态订阅（登录后调用 start）；返回退订函数。 */
  onStatus(listener: (status: string) => void): () => void {
    this.statusListeners.push(listener);
    return () => {
      const idx = this.statusListeners.indexOf(listener);
      if (idx >= 0) {
        this.statusListeners.splice(idx, 1);
      }
    };
  }

  get isLoggedIn(): boolean {
    return this.auth.isLoggedIn;
  }

  /** App 回到前台：已登录才立即重连（未登录不启动网络重试循环）。 */
  onAppForeground(): void {
    if (this.auth.isLoggedIn) {
      this.client.connectNow('foreground');
    }
  }

  /**
   * 让所有可控桌面保持 sessions 列表订阅和权威快照同步。
   *
   * 这是应用级同步，不依赖 TaskListPage 的生命周期：用户切到会话详情、后台再回前台，
   * 或者桌面端在列表页之外创建任务，都不会丢掉 sessions:created push。
   */
  syncSessionSubscriptions(): void {
    if (this.client.getStatus() !== 'online') return;

    const desiredDeviceIds: Set<string> = new Set();
    const devices = this.tasks.deviceList;
    for (let i = 0; i < devices.length; i++) {
      if (devices[i].online && devices[i].remoteControlEnabled) {
        desiredDeviceIds.add(devices[i].deviceId);
      }
    }

    const staleDeviceIds: string[] = [];
    this.sessionSubscribedDevices.forEach((deviceId: string) => {
      if (!desiredDeviceIds.has(deviceId)) staleDeviceIds.push(deviceId);
    });
    for (let i = 0; i < staleDeviceIds.length; i++) {
      const deviceId = staleDeviceIds[i];
      this.sessionSubscribedDevices.delete(deviceId);
      this.clearSessionRetries(deviceId);
      void this.unsubscribeSessions(deviceId);
    }

    for (let i = 0; i < devices.length; i++) {
      const deviceId = devices[i].deviceId;
      if (!desiredDeviceIds.has(deviceId)
        || this.sessionSubscribedDevices.has(deviceId)
        || this.sessionSubscriptionOperations.has(deviceId)
        || this.sessionSubscriptionRetryTimers.has(deviceId)) {
        continue;
      }
      const generation = this.sessionSubscriptionGeneration;
      this.sessionSubscriptionOperations.add(deviceId);
      void this.subscribeSessions(deviceId, generation);
    }
  }

  // ─── 内部 ───────────────────────────────────────────────────────────────────

  private buildHello(): HelloPayload {
    const hello = new HelloPayload();
    hello.deviceName = 'Cindy Harmony';
    hello.platform = AppConfig.platform;
    hello.appVersion = AppConfig.appVersion;
    // 鸿蒙端是控制端，不接受被远程控制。
    hello.remoteControlEnabled = false;
    hello.busy = false;
    return hello;
  }

  private buildEvents(): DlEvents {
    const events = new DlEvents();
    events.onStatus = (status: string) => {
      hilog.info(DOMAIN, TAG, 'device-link status=%{public}s', status);
      if (status === 'online') {
        // 重连成功：重新订阅已打开会话并 gap healing，刷新设备快照。
        this.messages.resubscribeAll();
        void this.loadDevices();
      } else {
        // relay 重连后旧 topic registry 已失效；让下一次 online 重新订阅。
        // link-open 也是连接级状态，不能沿用旧 socket 上的已建立标记。
        this.linkedDevices.clear();
        this.resetSessionSubscriptions();
      }
      for (const l of this.statusListeners) {
        l(status);
      }
    };
    events.onLinkClosed = (deviceId: string, reason: string) => {
      if (reason === 'revoked') {
        hilog.warn(DOMAIN, TAG, 'access revoked by device %{public}s', deviceId.slice(0, 8));
      }
    };
    events.onHelloAck = (ack: HelloAckPayload) => {
      // 握手成功：记录本机 deviceId，并拉一次 REST 设备快照作为列表基础。
      this.tasks.setSelfDeviceId(ack.deviceId);
      void this.loadDevices();
    };
    events.onAuthFailed = () => {
      // 握手被 401 拒：强制刷新 token 后立即重连。
      void this.recoverAuthAndReconnect();
    };
    events.onPresence = (snap: PresenceSnapshot) => {
      this.tasks.handlePresence(snap);
    };
    events.onPush = (deviceId: string, channel: string, payload: Object | undefined) => {
      this.dispatchPush(deviceId, channel, payload);
    };
    return events;
  }

  /** 401 后恢复：刷新 token → 重连；refresh 也失败则保持退避（不误登出）。 */
  private async recoverAuthAndReconnect(): Promise<void> {
    const token = await this.auth.forceRefreshToken();
    if (token !== null && token.length > 0) {
      this.client.connectNow('auth-refresh');
    } else {
      hilog.warn(DOMAIN, TAG, 'auth refresh failed after 401, keep backoff');
    }
  }

  /** 拉取全量设备快照（REST 管理面），presence 补丁保留在线状态不回退。 */
  async loadDevices(): Promise<void> {
    let retried = false;
    try {
      for (;;) {
      const token = await this.auth.getAccessToken();
      if (token === null || token.length === 0) {
        return;
      }
      const headers: Record<string, string> = {};
      headers['Authorization'] = `Bearer ${token}`;
      const res = await this.http.requestJson(
        `${AppConfig.deviceLinkApiBaseUrl}/api/device-link/devices`,
        'GET',
        headers,
        undefined,
      );
      if (res.statusCode === 401 && !retried) {
        // access token 过期：强制刷新后重试一次。
        retried = true;
        const refreshed = await this.auth.forceRefreshToken();
        if (refreshed !== null && refreshed.length > 0) {
          continue;
        }
        return;
      }
      if (res.statusCode >= 300) {
        hilog.warn(DOMAIN, TAG, 'load devices status=%{public}d', res.statusCode);
        return;
      }
      const views: DeviceView[] = [];
      let parsed: Object;
      try {
        parsed = JSON.parse(res.body) as Object;
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'load devices: response is not json');
        return;
      }
      // 兼容两种响应形态：直接数组，或 { devices: [...] }。
      let rawList: Object[] = [];
      if (Array.isArray(parsed)) {
        rawList = parsed as Object[];
      } else if (parsed !== undefined && typeof parsed === 'object' && !Array.isArray(parsed)) {
        const obj = parsed as Record<string, Object>;
        const inner = obj['devices'];
        if (Array.isArray(inner)) {
          rawList = inner as Object[];
        }
      }
      for (let i = 0; i < rawList.length; i++) {
        const raw = rawList[i];
        if (raw !== undefined && typeof raw === 'object' && !Array.isArray(raw)) {
          views.push(parseDeviceView(raw as Record<string, Object>));
        }
      }
      hilog.info(DOMAIN, TAG, 'load devices ok count=%{public}d', views.length);
      this.tasks.mergeServerDevices(views);
      this.syncSessionSubscriptions();
      for (let i = 0; i < views.length; i++) {
        if (views[i].online && views[i].remoteControlEnabled) {
          void this.messages.hydrateActiveSessions(views[i].deviceId);
        }
      }
      return;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'load devices failed: %{public}s', JSON.stringify(e));
    }
  }

  private dispatchPush(deviceId: string, channel: string, payload: Object | undefined): void {
    switch (channel) {
      case DlChannels.SESSIONS_CREATED:
      case DlChannels.SESSIONS_PATCHED:
      case DlChannels.SESSION_ACTIVITY:
      case DlChannels.SESSION_ERROR_PERSISTED:
        this.tasks.handleSessionsPush(deviceId, channel, payload);
        if (channel === DlChannels.SESSION_ACTIVITY) {
          this.messages.handleSessionActivity(payload);
        }
        break;
      case 'local-db:messages:created':
      case 'local-db:messages:deleted':
        this.messages.handleSessionPush(deviceId, channel, payload);
        break;
      case 'maker:event': {
        // 流式事件（text delta）→ 消息 Store 累积流式回复。
        if (payload !== undefined && typeof payload === 'object') {
          const p = payload as Record<string, Object>;
          const sid = readStr(p, 'sessionId');
          if (sid.length > 0) {
            this.messages.handleMakerEvent(sid, p['event']);
          }
        }
        break;
      }
      case 'maker:status-changed':
        this.messages.handleMakerStatusChanged(payload);
        break;
      case 'maker:interaction-request':
        this.interactions.handleInteractionRequest(payload);
        break;
      case 'maker:interaction-dismissed':
        this.interactions.handleInteractionDismissed(payload);
        break;
      case 'maker:input:projection':
        this.inputQueue.handleProjectionPush(payload);
        break;
      case 'maker:goal:status-changed':
        this.goals.handleStatusChanged(payload);
        break;
      default:
        // 未识别的 push channel 忽略（切片 2+ 逐步接入）。
        break;
    }
  }

  private async subscribeSessions(deviceId: string, generation: number): Promise<void> {
    try {
      await this.openLink(deviceId);
      if (!this.sessionSubscriptionStillNeeded(deviceId, generation)) return;
      await this.client.subscribe(deviceId, [SESSIONS_TOPIC]);
      if (!this.sessionSubscriptionStillNeeded(deviceId, generation)) {
        await this.unsubscribeSessions(deviceId);
        return;
      }
      this.sessionSubscribedDevices.add(deviceId);
      this.clearSessionSubscriptionRetry(deviceId);
      const loaded = await this.tasks.loadSessions(deviceId);
      if (loaded) {
        this.clearSessionSnapshotRetry(deviceId);
      } else if (this.sessionSubscriptionStillNeeded(deviceId, generation)) {
        this.scheduleSessionSnapshotRetry(deviceId, generation);
      }
    } catch (e) {
      if (this.sessionSubscriptionStillNeeded(deviceId, generation)) {
        this.scheduleSessionSubscriptionRetry(deviceId, generation);
      }
    } finally {
      this.sessionSubscriptionOperations.delete(deviceId);
      this.syncSessionSubscriptions();
    }
  }

  private sessionSubscriptionStillNeeded(deviceId: string, generation: number): boolean {
    if (generation !== this.sessionSubscriptionGeneration || this.client.getStatus() !== 'online') {
      return false;
    }
    const devices = this.tasks.deviceList;
    for (let i = 0; i < devices.length; i++) {
      if (devices[i].deviceId === deviceId) {
        return devices[i].online && devices[i].remoteControlEnabled;
      }
    }
    return false;
  }

  private scheduleSessionSubscriptionRetry(deviceId: string, generation: number): void {
    if (this.sessionSubscriptionRetryTimers.has(deviceId)) return;
    const retryCount = this.sessionSubscriptionRetryCounts.get(deviceId) ?? 0;
    this.sessionSubscriptionRetryCounts.set(deviceId, retryCount + 1);
    const timer = setTimeout(() => {
      this.sessionSubscriptionRetryTimers.delete(deviceId);
      if (this.sessionSubscriptionStillNeeded(deviceId, generation)) {
        this.syncSessionSubscriptions();
      }
    }, this.sessionRetryDelay(retryCount));
    this.sessionSubscriptionRetryTimers.set(deviceId, timer);
  }

  private scheduleSessionSnapshotRetry(deviceId: string, generation: number): void {
    if (this.sessionSnapshotRetryTimers.has(deviceId)) return;
    const retryCount = this.sessionSnapshotRetryCounts.get(deviceId) ?? 0;
    this.sessionSnapshotRetryCounts.set(deviceId, retryCount + 1);
    const timer = setTimeout(() => {
      this.sessionSnapshotRetryTimers.delete(deviceId);
      if (this.sessionSubscriptionStillNeeded(deviceId, generation)
        && this.sessionSubscribedDevices.has(deviceId)) {
        void this.retrySessionSnapshot(deviceId, generation);
      }
    }, this.sessionRetryDelay(retryCount));
    this.sessionSnapshotRetryTimers.set(deviceId, timer);
  }

  private async retrySessionSnapshot(deviceId: string, generation: number): Promise<void> {
    const loaded = await this.tasks.loadSessions(deviceId);
    if (loaded) {
      this.clearSessionSnapshotRetry(deviceId);
    } else if (this.sessionSubscriptionStillNeeded(deviceId, generation)) {
      this.scheduleSessionSnapshotRetry(deviceId, generation);
    }
  }

  private sessionRetryDelay(retryCount: number): number {
    return Math.min(30_000, 2_000 * Math.pow(2, Math.min(retryCount, 4)));
  }

  private async unsubscribeSessions(deviceId: string): Promise<void> {
    try {
      await this.client.unsubscribe(deviceId, [SESSIONS_TOPIC]);
    } catch (e) {
      // 设备离线或链路已失效时退订只是 best-effort。
    }
  }

  private clearSessionSubscriptionRetry(deviceId: string): void {
    const timer = this.sessionSubscriptionRetryTimers.get(deviceId);
    if (timer !== undefined) clearTimeout(timer);
    this.sessionSubscriptionRetryTimers.delete(deviceId);
    this.sessionSubscriptionRetryCounts.delete(deviceId);
  }

  private clearSessionSnapshotRetry(deviceId: string): void {
    const timer = this.sessionSnapshotRetryTimers.get(deviceId);
    if (timer !== undefined) clearTimeout(timer);
    this.sessionSnapshotRetryTimers.delete(deviceId);
    this.sessionSnapshotRetryCounts.delete(deviceId);
  }

  private clearSessionRetries(deviceId: string): void {
    this.clearSessionSubscriptionRetry(deviceId);
    this.clearSessionSnapshotRetry(deviceId);
  }

  private resetSessionSubscriptions(): void {
    this.sessionSubscriptionGeneration += 1;
    this.sessionSubscribedDevices.clear();
    this.sessionSubscriptionRetryTimers.forEach((timer: number) => clearTimeout(timer));
    this.sessionSnapshotRetryTimers.forEach((timer: number) => clearTimeout(timer));
    this.sessionSubscriptionRetryTimers.clear();
    this.sessionSubscriptionRetryCounts.clear();
    this.sessionSnapshotRetryTimers.clear();
    this.sessionSnapshotRetryCounts.clear();
  }
}
