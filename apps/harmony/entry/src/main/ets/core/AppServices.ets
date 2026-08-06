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
import { HelloPayload, HelloAckPayload, PresenceSnapshot, DlChannels } from './device-link/DlProtocol';
import { TaskStore } from './tasks/TaskStore';
import { DeviceView, parseDeviceView, readStr } from './tasks/TaskModels';
import { MessageStore } from './messages/MessageStore';
import { InteractionStore } from './interactions/InteractionStore';
import { GoalStore } from './goals/GoalStore';

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
  readonly interactions: InteractionStore = new InteractionStore();
  readonly goals: GoalStore = new GoalStore();
  readonly client: DlClient;
  private readonly http: HarmonyHttp = new HarmonyHttp();
  private statusListeners: Array<(status: string) => void> = [];
  /** 已建立控制链路的设备（openLink 幂等去重）。 */
  private linkedDevices: Set<string> = new Set();

  private constructor() {
    const opts = new DlClientOptions();
    opts.getWsUrl = () => AppConfig.deviceLinkWsUrl;
    opts.getToken = () => this.auth.getAccessToken();
    opts.getHello = () => this.buildHello();
    opts.createWs = () => new HarmonyWsAdapter();
    opts.events = this.buildEvents();
    this.client = new DlClient(opts);
    this.tasks.attach(this.client);
    this.messages.attach(this.client);
    this.interactions.attach(this.client);
    this.goals.attach(this.client);
    this.messages.setLinkOpener((deviceId: string) => this.openLink(deviceId));
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
        delay(8000),
      ]);
      // 成功才标记，失败/超时允许下次重试。
      this.linkedDevices.add(deviceId);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'openLink failed: %{public}s', JSON.stringify(e));
    }
  }

  async init(context: common.Context): Promise<void> {
    await this.auth.init(context);
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
      case 'maker:interaction-request':
        this.interactions.handleInteractionRequest(payload);
        break;
      case 'maker:interaction-dismissed':
        this.interactions.handleInteractionDismissed(payload);
        break;
      case 'maker:goal:status-changed':
        this.goals.handleStatusChanged(payload);
        break;
      default:
        // 未识别的 push channel 忽略（切片 2+ 逐步接入）。
        break;
    }
  }
}
