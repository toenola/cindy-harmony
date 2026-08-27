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
  CONTROLLER_CAPABILITIES, MAKER_EVENT_BATCH_CHANNEL, expandMakerEventBatchPayload,
} from './device-link/DlProtocol';
import { TaskStore } from './tasks/TaskStore';
import { TaskSearchStore } from './tasks/TaskSearchStore';
import { TaskProjectOrderStore } from './tasks/TaskProjectOrderStore';
import { snapshotDevices, TaskListSnapshotStore } from './tasks/TaskListSnapshotStore';
import { DeviceView, parseDeviceView, readStr, safeErrorMessage } from './tasks/TaskModels';
import { MessageStore } from './messages/MessageStore';
import { InteractionStore } from './interactions/InteractionStore';
import { GoalStore } from './goals/GoalStore';
import { SecurityObservabilityAdapter } from './observability/SecurityObservabilityAdapter';
import { InputQueueStore, isTerminalMakerInputEvent } from './messages/InputQueueStore';
import { ComposerDraftStore } from './messages/ComposerDraftStore';
import { TaskListPreferenceStore } from './tasks/TaskListPreferenceStore';
import { NewSessionCreationStore } from './tasks/NewSessionCreationStore';
import { SessionDeepLinkIntent, parseSessionDeepLink } from './navigation/SessionDeepLink';
import { TaskCompletionPushPreferenceStore } from './notifications/TaskCompletionPushPreferenceStore';
import { TaskCompletionPushService } from './notifications/TaskCompletionPushService';

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
  readonly taskSearch: TaskSearchStore = new TaskSearchStore();
  readonly taskProjectOrder: TaskProjectOrderStore = new TaskProjectOrderStore();
  readonly messages: MessageStore = new MessageStore();
  readonly inputQueue: InputQueueStore = new InputQueueStore();
  readonly composerDrafts: ComposerDraftStore = new ComposerDraftStore();
  readonly taskListPreferences: TaskListPreferenceStore = new TaskListPreferenceStore();
  readonly taskListSnapshot: TaskListSnapshotStore = new TaskListSnapshotStore();
  readonly taskCompletionPushPreference: TaskCompletionPushPreferenceStore =
    new TaskCompletionPushPreferenceStore();
  readonly taskCompletionPush: TaskCompletionPushService =
    new TaskCompletionPushService(this.taskCompletionPushPreference);
  readonly interactions: InteractionStore = new InteractionStore();
  readonly goals: GoalStore = new GoalStore();
  /**
   * 可选安全观测身份。默认 no-op：Harmony 侧真实 SDK 未提供，接入前需完成
   * 隐私 / 区域 / 签名 / 冷启动评审（阶段 6 外部依赖）。缺 SDK 不影响登录与退出。
   */
  readonly securityObservability: SecurityObservabilityAdapter =
    new SecurityObservabilityAdapter();
  /** 退后台需要释放的前台重资源回调（当前只有会话分享）。 */
  private backgroundReleaseHandlers: Array<() => void> = [];
  readonly newSessionCreations: NewSessionCreationStore = new NewSessionCreationStore();
  readonly client: DlClient;
  private readonly http: HarmonyHttp = new HarmonyHttp();
  private statusListeners: Array<(status: string) => void> = [];
  private deepLinkListeners: Array<() => void> = [];
  private pendingDeepLink: SessionDeepLinkIntent | null = null;
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
  /** 同一设备的 link-open 只允许一个在途请求；订阅、历史和发送共享它。 */
  private linkOperations: Map<string, Promise<void>> = new Map();
  /** 连接或账号切换后，旧 link-open 回包不得复活已建立标记。 */
  private linkGeneration: number = 0;
  /** REST 设备快照 single-flight；重连、页面刷新和账号恢复不能叠加请求。 */
  private deviceLoadInFlight: Promise<boolean> | undefined = undefined;
  /** 账号切换后不能让新账号加入旧账号的设备快照请求。 */
  private deviceLoadInFlightEpoch: number = -1;

  private constructor() {
    const opts = new DlClientOptions();
    opts.getWsUrl = () => AppConfig.deviceLinkWsUrl;
    opts.getToken = () => this.auth.getAccessToken();
    opts.getHello = () => this.buildHello();
    opts.createWs = () => new HarmonyWsAdapter();
    opts.events = this.buildEvents();
    this.client = new DlClient(opts);
    this.tasks.attach(this.client);
    this.taskSearch.attach(this.client, this.tasks, (deviceId: string) => this.openLink(deviceId));
    this.taskProjectOrder.attach(
      this.client,
      (deviceId: string) => this.openLink(deviceId),
      (): string => this.auth.cacheAccountId,
    );
    this.tasks.onChanged(() => {
      this.syncSessionSubscriptions();
      this.taskListSnapshot.save(() => snapshotDevices(
        this.tasks.deviceList,
        (deviceId: string) => this.tasks.getSessions(deviceId),
      ));
    });
    this.auth.setLogoutCleanup(async (): Promise<void> => {
      // 登出**开始**即清空观测身份，避免强杀 / 崩溃上报误归到上一个账号。
      this.securityObservability.clearUser();
      // 自动 token 失效路径不会经过 SettingsPage 的 client.stop()；这里也必须
      // 断开旧账号链路并清掉队列、交互和新建任务，避免下一账号读取旧投影。
      this.client.stop();
      // 这次是账号级清理；旧账号临时 topic 的补偿退订不能跨过
      // stop/新账号复用同一 deviceId，避免误伤新账号的同名会话。
      this.newSessionCreations.clearAll(false);
      this.inputQueue.clearAll();
      this.interactions.clearAll();
      await this.messages.clearAllCachedSessions();
      await this.taskListSnapshot.clear();
      this.taskProjectOrder.clearAll();
      this.tasks.clearAll();
      this.goals.clearAll();
    });
    this.messages.attach(this.client);
    this.inputQueue.attach(this.client);
    this.interactions.attach(this.client);
    this.goals.attach(this.client);
    this.messages.setLinkOpener((deviceId: string) => this.openLink(deviceId));
    // 消息驻留分类只认任务快照的权威 `source` 字段，不用标题猜测 scheduler。
    this.messages.setSessionSnapshotResolver(
      (sessionId: string, deviceId: string) => this.tasks.findSessionById(sessionId, deviceId));
    this.inputQueue.setLinkOpener((deviceId: string) => this.openLink(deviceId));
    this.interactions.setLinkOpener((deviceId: string) => this.openLink(deviceId));
    this.goals.setLinkOpener((deviceId: string) => this.openLink(deviceId));
    this.newSessionCreations.attach(
      this.client,
      this.tasks,
      this.inputQueue,
      this.messages,
      (deviceId: string) => this.openLink(deviceId),
    );
  }

  acceptDeepLinkUri(uri: string): boolean {
    const intent = parseSessionDeepLink(uri);
    if (intent === null) return false;
    this.pendingDeepLink = intent;
    for (let i = 0; i < this.deepLinkListeners.length; i++) this.deepLinkListeners[i]();
    return true;
  }

  peekPendingDeepLink(): SessionDeepLinkIntent | null {
    return this.pendingDeepLink;
  }

  consumePendingDeepLink(): SessionDeepLinkIntent | null {
    const intent = this.pendingDeepLink;
    this.pendingDeepLink = null;
    return intent;
  }

  onDeepLink(listener: () => void): () => void {
    this.deepLinkListeners.push(listener);
    return () => {
      const index = this.deepLinkListeners.indexOf(listener);
      if (index >= 0) this.deepLinkListeners.splice(index, 1);
    };
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
    const existing = this.linkOperations.get(deviceId);
    if (existing !== undefined) {
      await existing;
      return;
    }
    const operation = this.openLinkOnce(deviceId);
    this.linkOperations.set(deviceId, operation);
    try {
      await operation;
    } finally {
      if (this.linkOperations.get(deviceId) === operation) {
        this.linkOperations.delete(deviceId);
      }
    }
  }

  private async openLinkOnce(deviceId: string): Promise<void> {
    await this.client.waitUntilOnline(5000);
    const linkGeneration = this.linkGeneration;
    const authEpoch = this.auth.sessionEpoch;
    const opts = new DlOpenLinkOptions();
    opts.controllerName = 'Cindy Harmony';
    opts.appVersion = AppConfig.appVersion;
    opts.capabilities = CONTROLLER_CAPABILITIES.slice();
    try {
      await Promise.race([
        this.client.openLink(deviceId, opts),
        delay(8000).then(() => {
          throw new Error('Device Link open-link timeout');
        }),
      ]);
      // 只有真实 link-accept 才标记；超时必须允许下一次调用重试。
      if (linkGeneration !== this.linkGeneration
        || authEpoch !== this.auth.sessionEpoch
        || this.client.getStatus() !== 'online'
        || !this.auth.isLoggedIn) return;
      this.linkedDevices.add(deviceId);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'openLink failed: %{public}s', safeErrorMessage(e));
    }
  }

  async init(context: common.Context): Promise<void> {
    await Promise.all([
      this.auth.init(context),
      this.composerDrafts.init(context),
      this.taskListPreferences.init(context),
      this.taskListSnapshot.init(context),
      this.taskCompletionPushPreference.init(context),
      this.messages.initCache(context),
    ]);
    await this.taskCompletionPush.init(context);
  }

  /** 登录态确认后、网络握手前恢复可丢弃的任务列表首屏快照。 */
  restoreTaskListSnapshot(): void {
    const accountId = this.auth.cacheAccountId;
    this.taskListSnapshot.setAccountScope(accountId);
    this.messages.setCacheAccountScope(accountId);
    this.tasks.hydrateTaskListSnapshot(this.taskListSnapshot.restore());
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
      this.client.connectNow('foreground', true);
    }
  }

  /**
   * App 退到后台：释放只在前台有意义的重资源。
   *
   * 目前只有会话分享：截图位图与临时文件可能占用数十 MB，退后台后不该继续持有；
   * 由页面注册回调，避免 core 反向依赖页面。
   */
  onAppBackground(): void {
    for (let i = 0; i < this.backgroundReleaseHandlers.length; i++) {
      this.backgroundReleaseHandlers[i]();
    }
  }

  /** 注册退后台释放回调；返回反注册函数。 */
  registerBackgroundRelease(handler: () => void): () => void {
    this.backgroundReleaseHandlers.push(handler);
    return (): void => {
      const index = this.backgroundReleaseHandlers.indexOf(handler);
      if (index >= 0) this.backgroundReleaseHandlers.splice(index, 1);
    };
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
        this.newSessionCreations.onRelayOnline();
        this.messages.resubscribeAll();
        void this.inputQueue.resyncActiveSessions();
        void this.interactions.resyncActiveSessions();
        void this.loadDevices();
      } else {
        // relay 重连后旧 topic registry 已失效；让下一次 online 重新订阅。
        // link-open 也是连接级状态，不能沿用旧 socket 上的已建立标记。
        this.linkGeneration += 1;
        this.linkedDevices.clear();
        this.taskProjectOrder.resetConnectionFence();
        this.resetSessionSubscriptions();
        this.messages.invalidateLiveTailTrust();
        if (status === 'stopped') {
          this.newSessionCreations.clearAll();
          this.inputQueue.clearAll();
          this.interactions.clearAll();
          this.goals.clearAll();
        } else {
          this.inputQueue.invalidateActiveAuthorities();
        }
      }
      for (const l of this.statusListeners) {
        l(status);
      }
    };
    events.onLinkClosed = (deviceId: string, reason: string) => {
      if (reason === 'revoked') {
        hilog.warn(DOMAIN, TAG, 'access revoked by device %{public}s', deviceId.slice(0, 8));
        this.inputQueue.invalidateDevice(deviceId);
      }
    };
    events.onHelloAck = (ack: HelloAckPayload) => {
      // setStatus('online') 已在同一 hello-ack 处理链中触发 loadDevices；这里只记录
      // 本机身份，避免冷启动对设备 REST 发出两份完全相同的并发请求。
      this.tasks.setSelfDeviceId(ack.deviceId);
      const previousAccountId = this.auth.cacheAccountId;
      if (this.auth.rememberRelayUserId(ack.userId)) {
        void this.switchTaskListAccountScope(previousAccountId, ack.userId);
      }
    };
    events.onAuthFailed = () => {
      // 握手被 401 拒：强制刷新 token 后立即重连。
      void this.recoverAuthAndReconnect();
    };
    events.onPresence = (snap: PresenceSnapshot) => {
      this.tasks.handlePresence(snap);
      if (!snap.online || !snap.remoteControlEnabled) {
        this.inputQueue.invalidateDevice(snap.deviceId);
      } else {
        void this.inputQueue.resyncDevice(snap.deviceId);
      }
    };
    events.onPush = (
      deviceId: string,
      channel: string,
      payload: Object | undefined,
      ownerStamp: Object | undefined,
    ) => {
      this.dispatchPush(deviceId, channel, payload, ownerStamp);
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
  async loadDevices(): Promise<boolean> {
    const epoch = this.auth.sessionEpoch;
    const existing = this.deviceLoadInFlight;
    if (existing !== undefined && this.deviceLoadInFlightEpoch === epoch) {
      return await existing;
    }
    const operation = this.loadDevicesOnce();
    this.deviceLoadInFlight = operation;
    this.deviceLoadInFlightEpoch = epoch;
    try {
      return await operation;
    } finally {
      if (this.deviceLoadInFlight === operation) {
        this.deviceLoadInFlight = undefined;
        this.deviceLoadInFlightEpoch = -1;
      }
    }
  }

  private async loadDevicesOnce(): Promise<boolean> {
    const authEpoch = this.auth.sessionEpoch;
    let retried = false;
    try {
      for (;;) {
        const token = await this.auth.getAccessToken();
        if (token === null || token.length === 0) {
          return false;
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
          return false;
        }
        if (res.statusCode >= 300) {
          hilog.warn(DOMAIN, TAG, 'load devices status=%{public}d', res.statusCode);
          return false;
        }
        const views: DeviceView[] = [];
        let parsed: Object;
        try {
          parsed = JSON.parse(res.body) as Object;
        } catch (e) {
          hilog.warn(DOMAIN, TAG, 'load devices: response is not json');
          return false;
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
        if (authEpoch !== this.auth.sessionEpoch || !this.auth.isLoggedIn) return false;
        hilog.info(DOMAIN, TAG, 'load devices ok count=%{public}d', views.length);
        this.tasks.mergeServerDevices(views);
        const seenDeviceIds = new Set<string>();
        for (let i = 0; i < views.length; i++) seenDeviceIds.add(views[i].deviceId);
        const availableDeviceIds = new Set<string>();
        const mergedDevices = this.tasks.deviceList;
        for (let i = 0; i < mergedDevices.length; i++) {
          if (mergedDevices[i].online && mergedDevices[i].remoteControlEnabled) {
            availableDeviceIds.add(mergedDevices[i].deviceId);
          }
        }
        this.inputQueue.reconcileDeviceSnapshot(seenDeviceIds, availableDeviceIds);
        this.syncSessionSubscriptions();
        for (let i = 0; i < views.length; i++) {
          if (views[i].online && views[i].remoteControlEnabled) {
            void this.messages.hydrateActiveSessions(views[i].deviceId);
          }
        }
        return true;
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'load devices failed: %{public}s', safeErrorMessage(e));
      return false;
    }
  }

  private async switchTaskListAccountScope(previousAccountId: string, accountId: string): Promise<void> {
    if (previousAccountId.length > 0 && previousAccountId !== accountId) {
      // hello-ack 发现账号变化时未必经过 SettingsPage.logout；清理所有带
      // 账号语义的运行投影和应用级 sessions 订阅，不能只清任务/消息列表。
      this.linkGeneration += 1;
      this.linkedDevices.clear();
      this.resetSessionSubscriptions();
      // hello-ack 发现账号变化时同样丢弃旧账号 topic lease；当前连接可能已
      // 属于新账号，不能把旧账号的 pending unsubscribe 发到新账号。
      this.newSessionCreations.clearAll(false);
      this.inputQueue.clearAll();
      this.interactions.clearAll();
      await this.messages.clearAllCachedSessions();
      await this.taskListSnapshot.clear();
      this.taskProjectOrder.clearAll();
      this.tasks.clearAll();
      this.goals.clearAll();
    }
    this.taskListSnapshot.setAccountScope(accountId);
    this.messages.setCacheAccountScope(accountId);
    // 换号后立即重绑观测身份，避免后续崩溃上报归到上一个账号。
    this.securityObservability.bindUser(accountId);
    void this.loadDevices();
  }

  private dispatchPush(
    deviceId: string,
    channel: string,
    payload: Object | undefined,
    ownerStamp: Object | undefined = undefined,
  ): void {
    switch (channel) {
      case 'sidebar-settings:project-order-changed':
        this.taskProjectOrder.handlePush(deviceId, payload, ownerStamp);
        break;
      case DlChannels.SESSIONS_CREATED:
      case DlChannels.SESSIONS_PATCHED:
      case DlChannels.SESSION_ACTIVITY:
      case DlChannels.SESSION_ERROR_PERSISTED:
        this.tasks.handleSessionsPush(deviceId, channel, payload);
        if (channel === DlChannels.SESSION_ACTIVITY) {
          this.messages.handleSessionActivity(payload, deviceId);
        } else if (channel === DlChannels.SESSION_ERROR_PERSISTED) {
          this.messages.handleSessionPush(deviceId, channel, payload);
        }
        break;
      case 'local-db:messages:created':
      case 'local-db:messages:deleted':
        this.messages.handleSessionPush(deviceId, channel, payload);
        break;
      case 'maker:event': {
        this.dispatchMakerEventPayload(payload, deviceId);
        break;
      }
      case MAKER_EVENT_BATCH_CHANNEL: {
        const events = expandMakerEventBatchPayload(payload);
        for (let i = 0; i < events.length; i++) this.dispatchMakerEventPayload(events[i], deviceId);
        break;
      }
      case 'maker:status-changed':
        this.messages.handleMakerStatusChanged(payload, deviceId);
        if (payload !== undefined && typeof payload === 'object' && !Array.isArray(payload)) {
          const statusPayload = payload as Record<string, Object>;
          if (readStr(statusPayload, 'status') === 'closed') {
            this.inputQueue.noteTurnTerminal(readStr(statusPayload, 'sessionId'), deviceId);
          }
        }
        break;
      case 'maker:interaction-request':
        this.interactions.handleInteractionRequest(payload, deviceId);
        break;
      case 'maker:interaction-dismissed':
        this.interactions.handleInteractionDismissed(payload, deviceId);
        break;
      case 'maker:input:projection':
        this.inputQueue.handleProjectionPush(payload, deviceId);
        break;
      case 'maker:goal:status-changed':
        this.goals.handleStatusChanged(payload, deviceId);
        break;
      default:
        // 未识别的 push channel 忽略（切片 2+ 逐步接入）。
        break;
    }
  }

  /** 单条与微批展开后的事件共用唯一处理路径，保证状态/终态顺序完全一致。 */
  private dispatchMakerEventPayload(payload: Object | undefined, deviceId: string = ''): void {
    if (payload === undefined || payload === null || typeof payload !== 'object'
      || Array.isArray(payload)) return;
    const record = payload as Record<string, Object>;
    const sessionId = readStr(record, 'sessionId');
    if (sessionId.length === 0) return;
    this.messages.handleMakerEvent(
      sessionId, record['event'], readStr(record, 'persistId'), deviceId);
    if (isTerminalMakerInputEvent(record['event'])) {
      this.inputQueue.noteTurnTerminal(sessionId, deviceId);
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
