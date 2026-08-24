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
  HANDSHAKE_TIMEOUT_MS, RECONNECT_STABLE_RESET_MS,
  RECONNECT_CONGESTION_STABLE_RESET_MS, ReconnectStability,
  CONTROLLER_CAPABILITIES, encodeEnvelope, decodeEnvelope,
} from './DlProtocol';

const DOMAIN = 0x0000;
const TAG = 'CindyDl';

export class DlError extends Error {
  readonly code: string;
  /** true 表示请求帧可能已经交给 WebSocket，ACK 丢失时禁止调用方盲重。 */
  readonly inFlight: boolean;

  constructor(code: string, message: string, inFlight: boolean = false) {
    super(message);
    this.name = 'DlError';
    this.code = code;
    this.inFlight = inFlight;
  }
}

/** 只有能证明请求尚未发出的连接错误，才允许进入本地 outbox 自动续发。 */
export function isSafeUnsentDlError(value: Object | undefined): boolean {
  if (value instanceof DlError) {
    if (value.inFlight) return false;
    return value.code === 'NOT_CONNECTED'
      || value.code === 'BACKPRESSURE'
      || value.code === 'LINK_NOT_OPEN'
      || value.code === 'DEVICE_OFFLINE'
      || value.code === 'DEVICE_UNRESPONSIVE';
  }
  const message = value instanceof Error ? value.message : '';
  return message.indexOf('[NOT_CONNECTED]') >= 0
    || message.indexOf('[DEVICE_LINK_NOT_CONNECTED]') >= 0
    || message.indexOf('[BACKPRESSURE]') >= 0
    || message.indexOf('[LINK_NOT_OPEN]') >= 0
    || message.indexOf('[DEVICE_OFFLINE]') >= 0
    || message.indexOf('[DEVICE_UNRESPONSIVE]') >= 0;
}

/**
 * invoke-result 只有 `ok=true` 才算业务调用成功。
 *
 * request id 能配对只说明收到了响应；订阅被桌面端拒绝时也会返回 invoke-result。
 * 若把这种响应当成功，调用方会永久记成“已订阅”，之后不再重试 sessions topic。
 */
export function assertInvokeSucceeded(env: Envelope): void {
  if (env.payload === undefined || env.payload === null
    || typeof env.payload !== 'object' || Array.isArray(env.payload)) {
    throw new DlError('INVALID_RESPONSE', 'invoke result payload is invalid');
  }
  const payload = env.payload as Record<string, Object>;
  if (payload['ok'] === true) return;

  let code = 'IPC_ERROR';
  let message = 'invoke failed';
  const error = payload['error'];
  if (error !== undefined && error !== null && typeof error === 'object' && !Array.isArray(error)) {
    const record = error as Record<string, Object>;
    if (typeof record['code'] === 'string' && record['code'].length > 0) code = record['code'];
    if (typeof record['message'] === 'string' && record['message'].length > 0) message = record['message'];
  } else {
    if (typeof payload['errorCode'] === 'string' && payload['errorCode'].length > 0) {
      code = payload['errorCode'];
    }
    if (typeof payload['errorMessage'] === 'string' && payload['errorMessage'].length > 0) {
      message = payload['errorMessage'];
    }
  }
  throw new DlError(code, message);
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
  inFlight: boolean = false;
}

export class DlClient {
  private opts: DlClientOptions;
  private ws: WsAdapter | undefined = undefined;
  private wsCallbacks: WsCallbacks = new WsCallbacks();
  private status: string = 'stopped'; // 'stopped' | 'connecting' | 'online'
  private stopped = true;
  /**
   * 重连退避与 1013 拥塞稳定性状态（纯逻辑，单测覆盖计时语义与代次竞态）。
   * 普通退避连续在线 10 秒清零；1013 拥塞历史必须连续在线 15 分钟才清除——
   * 短暂重连成功不代表 relay 已恢复，提前清零会让客户端回到秒级重试打穿 relay。
   */
  private stability: ReconnectStability = new ReconnectStability();
  private reconnectTimer: number = -1;
  private handshakeTimer: number = -1;
  private heartbeatTimer: number = -1;
  private stableTimer: number = -1;
  /** 1013 拥塞期的独立稳定窗计时器，与普通退避窗互不影响。 */
  private congestionStableTimer: number = -1;
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
    this.stability.reset();
    void this.connect('start');
  }

  /** 前台恢复可显式绕过当前 1013 timer；普通请求不能打穿拥塞冷却。 */
  connectNow(reason: string, overrideCongestionCooldown: boolean = false): void {
    if (this.status === 'online') return;
    if (this.stopped) {
      this.stability.reset();
    } else if (this.stability.getCongestionStreak() > 0 && this.reconnectTimer >= 0
      && !overrideCongestionCooldown) {
      hilog.info(DOMAIN, TAG, 'connectNow parked by congestion cooldown streak=%{public}d',
        this.stability.getCongestionStreak());
      return;
    }
    this.stopped = false;
    this.stability.resetNormalBackoff();
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
      this.clearTimer(this.congestionStableTimer);
      this.congestionStableTimer = -1;
      // 断线即中断稳定期并推进代次：拥塞 streak 必须等下一次连接重新累计满 15 分钟
      // 才清除，旧计时器的结算在新连接上一律作废。
      this.stability.noteClosed(code);
      // 握手前断开且带 401/unauthorized 特征 → 触发 token 刷新重连。
      if (!this.helloAcked && !this.stopped && /\b401\b|unauthorized/i.test(`${code} ${reason}`)) {
        this.opts.events.onAuthFailed();
      }
      if (!this.stopped) {
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
        this.clearTimer(this.congestionStableTimer);
        this.congestionStableTimer = -1;
        // ws error 不是 relay 拥塞信号：只推进代次，不累计 1013 streak。
        this.stability.noteClosed(0);
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
    // 稳定在线后清零普通退避；1013 拥塞历史走独立的更长稳定窗。
    const onlineAtMs = Date.now();
    this.stability.noteOnline(onlineAtMs);
    const generation = this.stability.getGeneration();
    this.clearTimer(this.stableTimer);
    this.stableTimer = setTimeout(() => {
      this.stableTimer = -1;
      if (this.stopped || this.status !== 'online') return;
      this.stability.settleNormalWindow(generation, Date.now());
    }, RECONNECT_STABLE_RESET_MS);
    // 拥塞窗只在本次连接持续在线满 15 分钟后清除 streak：中途断线会推进代次让本次
    // 结算作废，期内新的 1013 继续累计。已在计时中则不重建，避免顺延窗口。
    if (this.stability.getCongestionStreak() > 0 && this.congestionStableTimer < 0) {
      this.congestionStableTimer = setTimeout(() => {
        this.congestionStableTimer = -1;
        if (this.stopped || this.status !== 'online') return;
        if (this.stability.settleCongestionWindow(generation, Date.now())) {
          hilog.info(DOMAIN, TAG, 'congestion cooldown cleared after stable window');
        }
      }, RECONNECT_CONGESTION_STABLE_RESET_MS);
    }
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
  async subscribe(deviceId: string, topics: string[], timeoutMs: number = REQUEST_TIMEOUT_MS): Promise<Envelope> {
    const arg = new SubscribeArgs();
    arg.topics = topics;
    arg.controllerName = this.opts.getHello().deviceName;
    arg.capabilities = CONTROLLER_CAPABILITIES.slice();
    const args: Object[] = [arg];
    const opts = new DlInvokeOptions();
    opts.channel = 'device-link:subscribe';
    opts.args = args;
    opts.timeoutMs = timeoutMs;
    const env = await this.invoke(deviceId, opts);
    assertInvokeSucceeded(env);
    return env;
  }

  /** 注销推送 topic。 */
  async unsubscribe(deviceId: string, topics: string[], timeoutMs: number = REQUEST_TIMEOUT_MS): Promise<Envelope> {
    const arg = new SubscribeArgs();
    arg.topics = topics;
    const args: Object[] = [arg];
    const opts = new DlInvokeOptions();
    opts.channel = 'device-link:unsubscribe';
    opts.args = args;
    opts.timeoutMs = timeoutMs;
    const env = await this.invoke(deviceId, opts);
    assertInvokeSucceeded(env);
    return env;
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
          reject(new DlError('INVOKE_TIMEOUT',
            `${kind} ${channel} timeout after ${timeoutMs}ms`, req.inFlight));
        }, timeoutMs);
        this.pending.set(id, req);
        // 在进入 send 前先按“可能已发出”处理；即使适配器同步触发 close，
        // failAllPending 也不能把这次写请求误判为可自动重放。
        req.inFlight = true;
        let sent = false;
        try {
          sent = this.sendEnvelope(env);
        } catch (e) {
          this.pending.delete(id);
          this.clearTimer(req.timer);
          const message = e instanceof Error ? e.message : JSON.stringify(e);
          reject(new DlError('SEND_FAILED', message, true));
          return;
        }
        if (!sent) {
          req.inFlight = false;
          this.pending.delete(id);
          this.clearTimer(req.timer);
          reject(new DlError('NOT_CONNECTED', 'socket unavailable before send'));
        }
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

  private sendEnvelope(env: Envelope): boolean {
    const ws = this.ws;
    if (!ws) return false;
    return ws.send(encodeEnvelope(env));
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
      req.reject(new DlError(err.code, err.message, err.inFlight || req.inFlight));
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
        // 心跳判死同样中断稳定期，旧计时器不得在新连接上清掉拥塞状态。
        this.clearTimer(this.stableTimer);
        this.stableTimer = -1;
        this.clearTimer(this.congestionStableTimer);
        this.congestionStableTimer = -1;
        // 心跳判死不是 relay 拥塞信号：只推进代次，不累计 1013 streak。
        this.stability.noteClosed(0);
        if (!this.stopped) this.scheduleReconnect('heartbeat-dead');
      }
    }, PING_INTERVAL_MS);
  }

  private scheduleReconnect(reason: string): void {
    if (this.stopped) return;
    if (this.reconnectTimer >= 0) return;
    const delay = this.stability.nextReconnectDelayMs(Math.random());
    this.setStatus('connecting');
    hilog.info(DOMAIN, TAG,
      'reconnect in %{public}d ms (reason=%{public}s congestion=%{public}d)',
      delay, reason, this.stability.getCongestionStreak());
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
    this.clearTimer(this.congestionStableTimer);
    this.congestionStableTimer = -1;
    // 显式停止时完整回收：推进代次让所有在途稳定窗结算作废。
    this.stability.noteClosed(0);
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
