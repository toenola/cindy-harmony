/**
 * Device Link 客户端（ArkTS 精简实现）。
 *
 * 行为对齐 packages/device-link/src/client.ts，只实现一期需要的路径：
 *  连接 → hello/hello-ack → 心跳(20s ping / pong miss 判死) → invoke/
 *  invoke-result（request id 配对 + 超时）→ push 分发 → link-open/link-accept
 *  → subscribe/unsubscribe → 指数退避重连(1s→30s, 稳定 10s 清零)。
 *
 * 一期不实现：可靠传输/分片重组（不声明 reliable-transport-v1 能力，桌面
 * 被控端自动走普通帧兼容路径）、notify 推送、多设备并发节流。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { WsAdapter, WsCallbacks } from '../../network/WsAdapter';
import {
  Envelope, EnvelopeKind, HelloPayload, HelloAckPayload, LinkOpenPayload,
  PresenceSnapshot, LinkClosePayload, PresenceSetPayload,
  PROTOCOL_VERSION, PING_INTERVAL_MS, PONG_MISS_LIMIT, REQUEST_TIMEOUT_MS,
  HANDSHAKE_TIMEOUT_MS, RECONNECT_STABLE_RESET_MS, RELAY_TRY_AGAIN_LATER_CLOSE_CODE,
  CONTROLLER_CAPABILITIES, computeReconnectDelayMs, encodeEnvelope, decodeEnvelope,
} from './DlProtocol';

const DOMAIN = 0x0000;
const TAG = 'CindyDl';

export class DlError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = 'DlError';
    this.code = code;
  }
}

/** 简单延时。 */
function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });
}

/** invoke 参数。 */
export class DlInvokeOptions {
  channel: string = '';
  args: Object[] = [];
  /** 0/缺省 = 使用默认 30s 超时。 */
  timeoutMs: number | undefined = undefined;
}

/** openLink 参数。 */
export class DlOpenLinkOptions {
  controllerName: string = '';
  appVersion: string = '';
  capabilities: string[] = [];
}

/** 事件回调集合（host 注入）。 */
export class DlEvents {
  /** 'stopped' | 'connecting' | 'online' */
  onStatus: (status: string) => void = (status: string) => {
  };
  onPresence: (snap: PresenceSnapshot) => void = (snap: PresenceSnapshot) => {
  };
  /** push 帧（src=deviceId） */
  onPush: (deviceId: string, channel: string, payload: Object | undefined) => void =
    (deviceId: string, channel: string, payload: Object | undefined) => {
    };
  /** 握手成功（hello-ack 收到）。 */
  onHelloAck: (ack: HelloAckPayload) => void = (ack: HelloAckPayload) => {
  };
  /** 握手前被拒/断开（疑似 401 token 失效），上层应刷新 token 后重连。 */
  onAuthFailed: () => void = () => {
  };
  /** 被控端主动 link-close（如撤权）。 */
  onLinkClosed: (deviceId: string, reason: string) => void =
    (deviceId: string, reason: string) => {
    };
}

export class DlClientOptions {
  getWsUrl: () => string = () => '';
  /** 每次(重)连前取新鲜 token；null = 无登录态，跳过本轮重连。 */
  getToken: () => Promise<string | null> = async () => null;
  getHello: () => HelloPayload = () => new HelloPayload();
  createWs: () => WsAdapter = () => {
    throw new DlError('NO_WS_FACTORY', 'createWs not injected');
  };
  events: DlEvents = new DlEvents();
}

class PendingRequest {
  resolve: (env: Envelope) => void = () => {
  };
  reject: (err: DlError) => void = () => {
  };
  timer: number = 0;
  label: string = '';
}

export class DlClient {
  private opts: DlClientOptions;
  private ws: WsAdapter | undefined = undefined;
  private wsCallbacks: WsCallbacks = new WsCallbacks();
  private status: string = 'stopped'; // 'stopped' | 'connecting' | 'online'
  private stopped = true;
  private reconnectAttempt = 0;
  /** 连续 1013 只在稳定在线 10s 后清零，防止重连洪峰反复打穿 relay。 */
  private congestionCloseStreak = 0;
  private reconnectTimer: number = -1;
  private handshakeTimer: number = -1;
  private heartbeatTimer: number = -1;
  private stableTimer: number = -1;
  private pongMiss = 0;
  private helloAcked = false;
  private requestSeq = (Date.now() % 1000000) + Math.floor(Math.random() * 1000);
  private pending: Map<string, PendingRequest> = new Map();
  private deviceId: string = '';
  private userId: string = '';

  constructor(opts: DlClientOptions) {
    this.opts = opts;
  }

  getStatus(): string {
    return this.status;
  }

  getDeviceId(): string {
    return this.deviceId;
  }

  /** 有界等待连接就绪；超时返回 false（调用方决定是否继续）。 */
  async waitUntilOnline(timeoutMs: number): Promise<boolean> {
    if (this.status === 'online') {
      return true;
    }
    if (this.reconnectTimer >= 0) this.connectNow('wait-until-online');
    const deadline = Date.now() + timeoutMs;
    while (this.status !== 'online' && Date.now() < deadline && !this.stopped) {
      await delay(200);
    }
    return this.status === 'online';
  }

  // ─── 生命周期 ───────────────────────────────────────────────────────────────

  start(): void {
    if (!this.stopped) return;
    this.stopped = false;
    this.reconnectAttempt = 0;
    this.congestionCloseStreak = 0;
    void this.connect('start');
  }

  /** 前台恢复可显式绕过当前 1013 timer；普通请求不能打穿拥塞冷却。 */
  connectNow(reason: string, overrideCongestionCooldown: boolean = false): void {
    if (this.status === 'online') return;
    if (this.stopped) {
      this.congestionCloseStreak = 0;
    } else if (this.congestionCloseStreak > 0 && this.reconnectTimer >= 0
      && !overrideCongestionCooldown) {
      hilog.info(DOMAIN, TAG, 'connectNow parked by congestion cooldown streak=%{public}d',
        this.congestionCloseStreak);
      return;
    }
    this.stopped = false;
    this.reconnectAttempt = 0;
    this.clearTimer(this.reconnectTimer);
    this.reconnectTimer = -1;
    void this.connect(reason);
  }

  stop(): void {
    if (this.stopped) return;
    this.stopped = true;
    this.clearAllTimers();
    this.failAllPending(new DlError('NOT_CONNECTED', 'client stopped'));
    if (this.ws) this.ws.terminate();
    this.ws = undefined;
    this.setStatus('stopped');
  }

  private async connect(reason: string): Promise<void> {
    if (this.stopped) return;
    this.setStatus('connecting');
    this.helloAcked = false;
    // 丢弃旧 socket 与在途请求
    this.failAllPending(new DlError('NOT_CONNECTED', `reconnect (${reason})`));
    if (this.ws) {
      this.ws.terminate();
      this.ws = undefined;
    }

    let token: string | null = null;
    try {
      token = await this.opts.getToken();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'getToken failed: %{public}s', JSON.stringify(e));
    }
    if (token === null || token.length === 0) {
      hilog.warn(DOMAIN, TAG, 'no token, schedule reconnect');
      this.scheduleReconnect('no-token');
      return;
    }
    if (this.stopped) return;

    const ws = this.opts.createWs();
    this.ws = ws;
    this.bindWs(ws);

    const url = this.opts.getWsUrl();
    const headers: Record<string, string> = {};
    headers['Authorization'] = `Bearer ${token}`;
    hilog.info(DOMAIN, TAG, 'connecting %{public}s (reason=%{public}s)', url, reason);
    ws.connect(url, headers);

    this.clearTimer(this.handshakeTimer);
    this.handshakeTimer = setTimeout(() => {
      if (!this.helloAcked && this.ws === ws) {
        hilog.warn(DOMAIN, TAG, 'handshake timeout');
        this.failAllPending(new DlError('NOT_CONNECTED', 'handshake timeout'));
        ws.terminate();
        this.ws = undefined;
        this.scheduleReconnect('handshake-timeout');
      }
    }, HANDSHAKE_TIMEOUT_MS);
  }

  private bindWs(ws: WsAdapter): void {
    const cb = new WsCallbacks();
    cb.onOpen = () => {
      if (this.ws !== ws) return;
      hilog.info(DOMAIN, TAG, 'ws open, send hello');
      const hello = this.opts.getHello();
      const env = new Envelope();
      env.kind = EnvelopeKind.HELLO;
      const payload: Record<string, Object> = {};
      payload['deviceName'] = hello.deviceName;
      payload['platform'] = hello.platform;
      payload['appVersion'] = hello.appVersion;
      payload['remoteControlEnabled'] = hello.remoteControlEnabled;
      payload['busy'] = hello.busy;
      env.payload = payload;
      this.sendEnvelope(env);
    };
    cb.onMessage = (data) => {
      if (this.ws !== ws) return;
      this.handleFrame(data.toString());
    };
    cb.onClose = (code: number, reason: string) => {
      if (this.ws !== ws) return;
      hilog.info(DOMAIN, TAG, 'ws closed code=%{public}d reason=%{public}s', code, reason);
      this.ws = undefined;
      this.failAllPending(new DlError('NOT_CONNECTED', `closed ${code} ${reason}`));
      this.clearTimer(this.heartbeatTimer);
      this.clearTimer(this.stableTimer);
      this.stableTimer = -1;
      // 握手前断开且带 401/unauthorized 特征 → 触发 token 刷新重连。
      if (!this.helloAcked && !this.stopped && /\b401\b|unauthorized/i.test(`${code} ${reason}`)) {
        this.opts.events.onAuthFailed();
      }
      if (!this.stopped) {
        if (code === RELAY_TRY_AGAIN_LATER_CLOSE_CODE) this.congestionCloseStreak += 1;
        this.scheduleReconnect(`close-${code}`);
      }
    };
    cb.onError = (err: Error) => {
      if (this.ws !== ws) return;
      hilog.warn(DOMAIN, TAG, 'ws error: %{public}s', err.message);
      // 握手前失败：401 → 触发 token 刷新重连；其他错误 → 立即重连
      // （鸿蒙侧 401 只触发 error 不触发 close，不能干等握手超时）。
      if (!this.helloAcked && !this.stopped) {
        if (/\b401\b|unauthorized/i.test(err.message)) {
          this.opts.events.onAuthFailed();
        }
        this.ws = undefined;
        this.failAllPending(new DlError('NOT_CONNECTED', `ws error: ${err.message}`));
        this.clearTimer(this.handshakeTimer);
        this.clearTimer(this.heartbeatTimer);
        this.clearTimer(this.stableTimer);
        this.stableTimer = -1;
        this.scheduleReconnect('ws-error');
      }
    };
    ws.setCallbacks(cb);
  }

  // ─── 帧处理 ─────────────────────────────────────────────────────────────────

  private handleFrame(text: string): void {
    const env = decodeEnvelope(text);
    if (env === null) {
      hilog.warn(DOMAIN, TAG, 'drop invalid frame');
      return;
    }
    switch (env.kind) {
      case EnvelopeKind.HELLO_ACK:
        this.handleHelloAck(env);
        break;
      case EnvelopeKind.PONG:
        this.pongMiss = 0;
        break;
      case EnvelopeKind.PRESENCE_CHANGED:
        this.handlePresence(env);
        break;
      case EnvelopeKind.INVOKE_RESULT:
        this.handleInvokeResult(env);
        break;
      case EnvelopeKind.LINK_ACCEPT:
        this.handleLinkAccept(env);
        break;
      case EnvelopeKind.LINK_CLOSE:
        this.handleLinkClose(env);
        break;
      case EnvelopeKind.PUSH:
        this.handlePush(env);
        break;
      case EnvelopeKind.RELAY_ERROR:
        this.handleRelayError(env);
        break;
      default:
        hilog.warn(DOMAIN, TAG, 'unhandled kind=%{public}s', env.kind);
    }
  }

  private handleHelloAck(env: Envelope): void {
    const ack = new HelloAckPayload();
    const p = this.payloadObj(env);
    ack.serverProtocolVersion = this.readNum(p, 'serverProtocolVersion', 0);
    ack.deviceId = this.readStr(p, 'deviceId');
    ack.userId = this.readStr(p, 'userId');
    if (ack.serverProtocolVersion !== PROTOCOL_VERSION) {
      hilog.error(DOMAIN, TAG, 'protocol version mismatch server=%{public}d client=%{public}d',
        ack.serverProtocolVersion, PROTOCOL_VERSION);
      this.ws?.terminate();
      return;
    }
    this.deviceId = ack.deviceId;
    this.userId = ack.userId;
    this.helloAcked = true;
    this.clearTimer(this.handshakeTimer);
    this.setStatus('online');
    this.startHeartbeat();
    // 稳定在线后清零退避
    this.clearTimer(this.stableTimer);
    this.stableTimer = setTimeout(() => {
      this.stableTimer = -1;
      if (this.stopped || this.status !== 'online') return;
      this.reconnectAttempt = 0;
      this.congestionCloseStreak = 0;
    }, RECONNECT_STABLE_RESET_MS);
    this.opts.events.onHelloAck(ack);
  }

  private handlePresence(env: Envelope): void {
    const snap = new PresenceSnapshot();
    const p = this.payloadObj(env);
    snap.deviceId = this.readStr(p, 'deviceId');
    snap.online = this.readBool(p, 'online', false);
    snap.deviceName = this.readStr(p, 'deviceName');
    snap.platform = this.readStr(p, 'platform');
    snap.appVersion = this.readStr(p, 'appVersion');
    snap.lastSeenAt = this.readNum(p, 'lastSeenAt', 0);
    snap.remoteControlEnabled = this.readBool(p, 'remoteControlEnabled', false);
    snap.busy = this.readBool(p, 'busy', false);
    if (snap.deviceId.length === 0) return;
    this.opts.events.onPresence(snap);
  }

  private handleInvokeResult(env: Envelope): void {
    const req = this.takePending(env.id);
    if (req === undefined) return;
    this.clearTimer(req.timer);
    req.resolve(env);
  }

  private handleLinkAccept(env: Envelope): void {
    const req = this.takePending(env.id);
    if (req === undefined) return;
    this.clearTimer(req.timer);
    req.resolve(env);
  }

  private handleLinkClose(env: Envelope): void {
    const p = this.payloadObj(env);
    const reason = this.readStr(p, 'reason');
    this.opts.events.onLinkClosed(env.src, reason);
  }

  private handlePush(env: Envelope): void {
    const p = this.payloadObj(env);
    const channel = this.readStr(p, 'channel');
    const payload = p['payload'];
    this.opts.events.onPush(env.src, channel, payload);
  }

  private handleRelayError(env: Envelope): void {
    const p = this.payloadObj(env);
    const code = this.readStr(p, 'code');
    const message = this.readStr(p, 'message');
    const req = this.takePending(env.id);
    if (req !== undefined) {
      this.clearTimer(req.timer);
      req.reject(new DlError(code.length > 0 ? code : 'RELAY_ERROR', message));
    }
  }

  // ─── 对外能力 ───────────────────────────────────────────────────────────────

  /** 向目标设备发 invoke，返回原始响应帧（调用方解析 invoke-result payload）。 */
  invoke(deviceId: string, options: DlInvokeOptions): Promise<Envelope> {
    const timeout = options.timeoutMs !== undefined && options.timeoutMs > 0
      ? options.timeoutMs
      : REQUEST_TIMEOUT_MS;
    return this.requestEnvelope(EnvelopeKind.INVOKE, deviceId, options.channel,
      options.args, timeout);
  }

  /** 建立控制链路（link-open → 等 link-accept）。 */
  openLink(deviceId: string, options: DlOpenLinkOptions): Promise<Envelope> {
    const payload = new LinkOpenPayload();
    payload.controllerName = options.controllerName;
    payload.protocolVersion = PROTOCOL_VERSION;
    payload.appVersion = options.appVersion;
    payload.capabilities = options.capabilities;
    return this.requestEnvelope(EnvelopeKind.LINK_OPEN, deviceId, '', [payload],
      REQUEST_TIMEOUT_MS);
  }

  /** 显式关闭控制链路。 */
  closeLink(deviceId: string, reason: string): void {
    const close = new LinkClosePayload();
    close.reason = reason;
    const env = new Envelope();
    env.kind = EnvelopeKind.LINK_CLOSE;
    env.dst = deviceId;
    env.payload = close;
    this.sendEnvelope(env);
  }

  /** 订阅推送 topic（device-link:subscribe 控制帧）。 */
  subscribe(deviceId: string, topics: string[], timeoutMs: number = REQUEST_TIMEOUT_MS): Promise<Envelope> {
    const arg = new SubscribeArgs();
    arg.topics = topics;
    arg.controllerName = this.opts.getHello().deviceName;
    arg.capabilities = CONTROLLER_CAPABILITIES.slice();
    const args: Object[] = [arg];
    const opts = new DlInvokeOptions();
    opts.channel = 'device-link:subscribe';
    opts.args = args;
    opts.timeoutMs = timeoutMs;
    return this.invoke(deviceId, opts);
  }

  /** 注销推送 topic。 */
  unsubscribe(deviceId: string, topics: string[], timeoutMs: number = REQUEST_TIMEOUT_MS): Promise<Envelope> {
    const arg = new SubscribeArgs();
    arg.topics = topics;
    const args: Object[] = [arg];
    const opts = new DlInvokeOptions();
    opts.channel = 'device-link:unsubscribe';
    opts.args = args;
    opts.timeoutMs = timeoutMs;
    return this.invoke(deviceId, opts);
  }

  /** 更新自身 presence（fire-and-forget）。 */
  setPresence(remoteControlEnabled: boolean, busy: boolean): void {
    const p = new PresenceSetPayload();
    p.remoteControlEnabled = remoteControlEnabled;
    p.busy = busy;
    const env = new Envelope();
    env.kind = EnvelopeKind.PRESENCE_SET;
    env.payload = p;
    this.sendEnvelope(env);
  }

  // ─── 内部 ───────────────────────────────────────────────────────────────────

  private requestEnvelope(
    kind: string,
    dst: string,
    channel: string,
    args: Object[],
    timeoutMs: number,
  ): Promise<Envelope> {
    const doSend = (): Promise<Envelope> => {
      if (this.status !== 'online') {
        return Promise.reject(new DlError('NOT_CONNECTED', 'not online'));
      }
      const id = this.nextId();
      const env = new Envelope();
      env.kind = kind;
      env.id = id;
      env.dst = dst;
      if (kind === EnvelopeKind.INVOKE) {
        const ip = new InvokePayloadForSend();
        ip.channel = channel;
        ip.args = args;
        env.payload = ip;
      } else {
        env.payload = args.length > 0 ? args[0] : undefined;
      }
      return new Promise<Envelope>((resolve, reject) => {
        const req = new PendingRequest();
        req.resolve = resolve;
        req.reject = reject;
        req.label = `${kind}:${channel}`;
        req.timer = setTimeout(() => {
          this.pending.delete(id);
          reject(new DlError('INVOKE_TIMEOUT', `${kind} ${channel} timeout after ${timeoutMs}ms`));
        }, timeoutMs);
        this.pending.set(id, req);
        this.sendEnvelope(env);
      });
    };
    if (this.status === 'online') {
      return doSend();
    }
    // 未在线：等待连接就绪（连接中 / 重连中不立即失败，让首拉与手动重试自动恢复）。
    return this.waitUntilOnline(timeoutMs).then((ok: boolean) => {
      if (!ok) {
        return Promise.reject(new DlError('NOT_CONNECTED', 'wait online timeout'));
      }
      return doSend();
    });
  }

  private sendEnvelope(env: Envelope): void {
    const ws = this.ws;
    if (!ws) return;
    ws.send(encodeEnvelope(env));
  }

  private takePending(id: string): PendingRequest | undefined {
    const req = this.pending.get(id);
    if (req === undefined) return undefined;
    this.pending.delete(id);
    return req;
  }

  private failAllPending(err: DlError): void {
    this.pending.forEach((req: PendingRequest, id: string) => {
      this.clearTimer(req.timer);
      req.reject(err);
    });
    this.pending.clear();
  }

  private startHeartbeat(): void {
    this.clearTimer(this.heartbeatTimer);
    this.pongMiss = 0;
    this.heartbeatTimer = setInterval(() => {
      const env = new Envelope();
      env.kind = EnvelopeKind.PING;
      env.id = `ping-${this.nextSeq()}`;
      this.sendEnvelope(env);
      this.pongMiss += 1;
      if (this.pongMiss >= PONG_MISS_LIMIT) {
        hilog.warn(DOMAIN, TAG, 'heartbeat dead, force reconnect');
        this.clearTimer(this.heartbeatTimer);
        this.failAllPending(new DlError('NOT_CONNECTED', 'heartbeat dead'));
        this.ws?.terminate();
        this.ws = undefined;
        if (!this.stopped) this.scheduleReconnect('heartbeat-dead');
      }
    }, PING_INTERVAL_MS);
  }

  private scheduleReconnect(reason: string): void {
    if (this.stopped) return;
    if (this.reconnectTimer >= 0) return;
    const delay = computeReconnectDelayMs(
      this.reconnectAttempt, this.congestionCloseStreak, Math.random());
    this.reconnectAttempt += 1;
    this.setStatus('connecting');
    hilog.info(DOMAIN, TAG,
      'reconnect in %{public}d ms (reason=%{public}s congestion=%{public}d)',
      delay, reason, this.congestionCloseStreak);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      void this.connect(reason);
    }, delay);
  }

  private setStatus(s: string): void {
    if (this.status === s) return;
    this.status = s;
    this.opts.events.onStatus(s);
  }

  private nextId(): string {
    return `r${this.nextSeq()}`;
  }

  private nextSeq(): number {
    this.requestSeq += 1;
    return this.requestSeq;
  }

  private clearTimer(timer: number): void {
    if (timer >= 0) {
      clearTimeout(timer);
    }
  }

  private clearAllTimers(): void {
    this.clearTimer(this.reconnectTimer);
    this.reconnectTimer = -1;
    this.clearTimer(this.handshakeTimer);
    this.handshakeTimer = -1;
    this.clearTimer(this.heartbeatTimer);
    this.heartbeatTimer = -1;
    this.clearTimer(this.stableTimer);
    this.stableTimer = -1;
  }

  private payloadObj(env: Envelope): Record<string, Object> {
    if (env.payload !== undefined && typeof env.payload === 'object') {
      return env.payload as Record<string, Object>;
    }
    return {};
  }

  private readStr(obj: Record<string, Object>, key: string): string {
    const v = obj[key];
    return typeof v === 'string' ? v : '';
  }

  private readNum(obj: Record<string, Object>, key: string, def: number): number {
    const v = obj[key];
    return typeof v === 'number' ? v : def;
  }

  private readBool(obj: Record<string, Object>, key: string, def: boolean): boolean {
    const v = obj[key];
    return typeof v === 'boolean' ? v : def;
  }
}

class InvokePayloadForSend {
  channel: string = '';
  args: Object[] = [];
}

/** device-link:subscribe / unsubscribe 的控制帧参数。 */
class SubscribeArgs {
  topics: string[] = [];
  controllerName: string = '';
  capabilities: string[] = [];
}
