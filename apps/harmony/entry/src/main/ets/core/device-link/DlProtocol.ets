/**
 * Device Link 协议类型与常量（ArkTS 版）。
 *
 * 以 packages/device-link-protocol/src/protocol.ts 为唯一权威源，
 * 本文件只承载鸿蒙端需要的子集：信封、连接层 payload、隧道层 payload 与
 * 业务 channel / topic 常量。任何协议改动必须先改权威源再同步本文件。
 */

// ─── 常量 ───────────────────────────────────────────────────────────────────

export const PROTOCOL_VERSION = 1;
export const MAX_FRAME_BYTES = 2 * 1024 * 1024;

/** 心跳间隔（client→server ping，20s）。 */
export const PING_INTERVAL_MS = 20_000;
/** 连续无 pong 判定僵死的周期数。 */
export const PONG_MISS_LIMIT = 2;
/** invoke / link-open 默认等待响应时长。 */
export const REQUEST_TIMEOUT_MS = 30_000;
/** 从 socket 创建到 hello-ack 的握手上限。 */
export const HANDSHAKE_TIMEOUT_MS = 15_000;
/** 重连退避：1s → 30s。 */
export const RECONNECT_BASE_MS = 1_000;
export const RECONNECT_MAX_MS = 30_000;
/** hello-ack 后稳定在线该时长才清零普通重连退避。 */
export const RECONNECT_STABLE_RESET_MS = 10_000;
/**
 * 1013 拥塞历史需要更长的稳定期才清除。
 *
 * 短暂重连成功不代表 relay 已恢复：若与普通退避共用 10 秒窗，一次短连接就会抹掉
 * 拥塞 streak，客户端立刻回到 1 秒级重试，形成 1013 高频抖动。拥塞期按连续成功
 * 15 分钟结算，期内新的 1013 继续累计并延长冷却。
 */
export const RECONNECT_CONGESTION_STABLE_RESET_MS = 900_000;
/** relay 1013 表示服务端拥塞；该信号使用独立的 5s→30s 冷却下限。 */
export const RELAY_TRY_AGAIN_LATER_CLOSE_CODE = 1013;
export const RECONNECT_CONGESTION_BASE_MS = 5_000;
export const RECONNECT_CONGESTION_MAX_MS = 30_000;

/** 普通指数退避与 1013 拥塞下限取较大值，再做 0.7x–1.0x 向下抖动。 */
export function computeReconnectDelayMs(  attemptValue: number,
  congestionStreakValue: number,
  randomValue: number,
): number {
  const attempt = Number.isFinite(attemptValue) ? Math.max(0, Math.floor(attemptValue)) : 0;
  const streak = Number.isFinite(congestionStreakValue)
    ? Math.max(0, Math.floor(congestionStreakValue)) : 0;
  const random = Number.isFinite(randomValue) ? Math.min(Math.max(randomValue, 0), 1) : 0;
  const normal = Math.min(RECONNECT_BASE_MS * Math.pow(2, attempt), RECONNECT_MAX_MS);
  const congestion = streak > 0
    ? Math.min(RECONNECT_CONGESTION_BASE_MS * Math.pow(2, streak - 1), RECONNECT_CONGESTION_MAX_MS)
    : 0;
  return Math.round(Math.max(normal, congestion) * (0.7 + random * 0.3));
}

/**
 * 重连稳定性状态机（纯逻辑，便于测试计时语义与代次竞态）。
 *
 * 两条独立的稳定窗：
 * - 普通退避：连续在线 10 秒后清零 attempt；
 * - 1013 拥塞：连续在线 15 分钟后才清除 streak / cooldown。
 *
 * 每次断开都推进代次；旧代次的稳定窗结算一律作废，不得作用到新连接。
 */
export class ReconnectStability {
  private attempt = 0;
  private congestionStreak = 0;
  private generation = 0;
  /** 本次连接在线起始时刻；<0 表示当前不在线。 */
  private onlineSinceMs = -1;
  /** 进入在线时的代次，用于识别跨连接的过期结算。 */
  private onlineGeneration = -1;

  getAttempt(): number {
    return this.attempt;
  }

  getCongestionStreak(): number {
    return this.congestionStreak;
  }

  getGeneration(): number {
    return this.generation;
  }

  /** 计划一次重连：返回本次应使用的延迟。 */
  nextReconnectDelayMs(randomValue: number): number {
    const delay = computeReconnectDelayMs(this.attempt, this.congestionStreak, randomValue);
    this.attempt += 1;
    return delay;
  }

  /** hello-ack：本次连接进入在线。 */
  noteOnline(nowMs: number): void {
    this.onlineSinceMs = nowMs;
    this.onlineGeneration = this.generation;
  }

  /**
   * 断开：推进代次并结束在线期。1013 关闭码累计拥塞 streak；
   * 正常关闭、鉴权失败和网络切换不得伪装成 1013。
   */
  noteClosed(closeCode: number): void {
    if (closeCode === RELAY_TRY_AGAIN_LATER_CLOSE_CODE) this.congestionStreak += 1;
    this.onlineSinceMs = -1;
    this.onlineGeneration = -1;
    this.generation += 1;
  }

  /**
   * 稳定窗结算。generation 为计时器登记时的代次；与当前代次不一致说明中间已断线，
   * 结算作废。返回本次是否真的清除了对应状态。
   */
  settleNormalWindow(generation: number, nowMs: number): boolean {
    if (!this.windowStillValid(generation, nowMs, RECONNECT_STABLE_RESET_MS)) return false;
    this.attempt = 0;
    return true;
  }

  settleCongestionWindow(generation: number, nowMs: number): boolean {
    if (this.congestionStreak === 0) return false;
    if (!this.windowStillValid(generation, nowMs, RECONNECT_CONGESTION_STABLE_RESET_MS)) return false;
    this.congestionStreak = 0;
    return true;
  }

  /** 显式重置（start / 用户主动清除冷却）。 */
  reset(): void {
    this.attempt = 0;
    this.congestionStreak = 0;
    this.onlineSinceMs = -1;
    this.onlineGeneration = -1;
    this.generation += 1;
  }

  /**
   * 只清普通退避（用户主动发起连接时立即重试一次）。
   * 拥塞历史必须保留：主动连接不代表 relay 已恢复。
   */
  resetNormalBackoff(): void {
    this.attempt = 0;
  }

  private windowStillValid(generation: number, nowMs: number, requiredMs: number): boolean {
    if (generation !== this.generation) return false;
    if (this.onlineSinceMs < 0 || this.onlineGeneration !== this.generation) return false;
    return nowMs - this.onlineSinceMs >= requiredMs;
  }
}

// ─── 信封 ────────────────────────────────────────────────────────────────────

/** 帧种类（relay 路由 + 隧道层）。 */
export class EnvelopeKind {
  static readonly HELLO = 'hello';
  static readonly HELLO_ACK = 'hello-ack';
  static readonly PRESENCE_SET = 'presence-set';
  static readonly PRESENCE_CHANGED = 'presence-changed';
  static readonly PING = 'ping';
  static readonly PONG = 'pong';
  static readonly LINK_OPEN = 'link-open';
  static readonly LINK_ACCEPT = 'link-accept';
  static readonly LINK_CLOSE = 'link-close';
  static readonly INVOKE = 'invoke';
  static readonly INVOKE_RESULT = 'invoke-result';
  static readonly PUSH = 'push';
  static readonly RELAY_ERROR = 'relay-error';
}

/** 统一信封。src 由 server 填；payload 为任意 JSON 对象。 */
export class Envelope {
  v: number = PROTOCOL_VERSION;
  kind: string = '';
  id: string = '';
  src: string = '';
  dst: string = '';
  payload: Object | undefined = undefined;
}

export function encodeEnvelope(env: Envelope): string {
  const out: Record<string, Object> = {};
  out['v'] = env.v;
  out['kind'] = env.kind;
  if (env.id.length > 0) out['id'] = env.id;
  if (env.src.length > 0) out['src'] = env.src;
  if (env.dst.length > 0) out['dst'] = env.dst;
  if (env.payload !== undefined) out['payload'] = env.payload;
  return JSON.stringify(out);
}

/** 解码并做最小校验；非法帧返回 null。 */
export function decodeEnvelope(text: string): Envelope | null {
  let raw: Object;
  try {
    raw = JSON.parse(text) as Object;
  } catch (e) {
    return null;
  }
  const obj = raw as Record<string, Object>;
  const kind = obj['kind'];
  if (typeof kind !== 'string' || kind.length === 0) {
    return null;
  }
  const env = new Envelope();
  env.kind = kind;
  const v = obj['v'];
  env.v = typeof v === 'number' ? v : PROTOCOL_VERSION;
  const id = obj['id'];
  env.id = typeof id === 'string' ? id : '';
  const src = obj['src'];
  env.src = typeof src === 'string' ? src : '';
  const dst = obj['dst'];
  env.dst = typeof dst === 'string' ? dst : '';
  env.payload = obj['payload'];
  return env;
}

// ─── 连接层 payload ──────────────────────────────────────────────────────────

export class HelloPayload {
  deviceName: string = '';
  platform: string = '';
  appVersion: string = '';
  remoteControlEnabled: boolean = true;
  busy: boolean = false;
}

export class HelloAckPayload {
  serverProtocolVersion: number = 0;
  deviceId: string = '';
  userId: string = '';
}

export class PresenceSetPayload {
  remoteControlEnabled: boolean | undefined = undefined;
  busy: boolean | undefined = undefined;
}

/** presence-changed 广播 / 设备列表共用的设备快照。 */
export class PresenceSnapshot {
  deviceId: string = '';
  online: boolean = false;
  deviceName: string = '';
  platform: string = '';
  appVersion: string = '';
  lastSeenAt: number = 0;
  remoteControlEnabled: boolean = false;
  busy: boolean = false;
}

// ─── 隧道层 payload ──────────────────────────────────────────────────────────

export class LinkOpenPayload {
  controllerName: string = '';
  protocolVersion: number = PROTOCOL_VERSION;
  appVersion: string = '';
  /** 端到端可选能力（append-only）。一期不声明可靠传输 → 桌面走普通帧兼容路径。 */
  capabilities: string[] = [];
}

export class LinkAcceptPayload {
  appVersion: string = '';
  allowlistHash: string = '';
}

export class LinkClosePayload {
  reason: string = '';
}

export class InvokePayload {
  channel: string = '';
  args: Object[] = [];
}

export class InvokeResultPayload {
  ok: boolean = false;
  result: Object | undefined = undefined;
  errorCode: string = '';
  errorMessage: string = '';
}

export class PushPayload {
  channel: string = '';
  payload: Object | undefined = undefined;
}

// ─── 业务 channel 与 topic 常量 ──────────────────────────────────────────────

export class DlChannels {
  /** 订阅 / 注销推送 topic（invoke 帧承载）。 */
  static readonly SUBSCRIBE = 'device-link:subscribe';
  static readonly UNSUBSCRIBE = 'device-link:unsubscribe';

  /** 会话列表读模型。 */
  static readonly SESSIONS_LIST = 'local-db:sessions:list';
  static readonly SESSIONS_GET = 'local-db:sessions:get';
  /** 新建任务与远端项目目录浏览（沿用 Device Link 既有 allowlist 契约）。 */
  static readonly MAKER_CREATE_SESSION = 'maker:create-session';
  static readonly FS_LIST_DIR = 'fs:list-dir';
  /** 历史消息（分页）。 */
  static readonly HISTORY_MESSAGES = 'local-db:history:messages';
  static readonly MESSAGES_LIST = 'local-db:messages:list';

  /** 发送消息 / 停止执行。 */
  static readonly MAKER_SEND = 'maker:send';
  static readonly MAKER_ABORT = 'maker:abort-session';
  /** 输入队列（与 Mobile transport 的公开通道同源）。 */
  static readonly INPUT_GET_PROJECTION = 'maker:input:get-projection';
  static readonly INPUT_ENQUEUE = 'maker:input:enqueue';
  static readonly INPUT_STEER = 'maker:input:steer';
  static readonly INPUT_STOP = 'maker:input:stop';
  static readonly INPUT_RESUME = 'maker:input:resume';
  static readonly INPUT_RETRY_ERROR = 'maker:input:retry-last-error';
  static readonly INPUT_CLEAR_ERROR = 'maker:input:clear-error';
  static readonly INPUT_REMOVE = 'maker:input:remove';
  static readonly INPUT_UPDATE_CONTENT = 'maker:input:update-content';
  static readonly INPUT_MOVE = 'maker:input:move';
  static readonly INPUT_SET_EDIT_LOCK = 'maker:input:set-edit-lock';
  /** 当前被控端处于 turn 中的会话快照。 */
  static readonly MAKER_LIST_ACTIVE = 'maker:list-active';
  /** 指定会话是否处于 turn 中。 */
  static readonly MAKER_SESSION_IN_TURN = 'maker:session-in-turn';

  /** 从被控桌面取回历史消息里的本地媒体。 */
  static readonly MEDIA_FETCH = 'device-link:media:fetch';
  /** 读取被控端生成的文本 / 代码文件预览。 */
  static readonly TEXT_FILE_READ_PREVIEW = 'text-file:read-preview';

  /** 会话列表级 push channel（归 sessions topic）。 */
  static readonly SESSIONS_CREATED = 'local-db:sessions:created';
  static readonly SESSIONS_PATCHED = 'local-db:sessions:patched';
  static readonly SESSION_ACTIVITY = 'local-db:sessions:activity';
  static readonly SESSION_ERROR_PERSISTED = 'local-db:session:error-persisted';
}

/** 控制端能消费 maker:event 微批；link-open 与 subscribe 必须同时声明。 */
export const CONTROLLER_CAPABILITY_MAKER_EVENT_BATCH_V1 = 'maker-event-batch-v1';
export const CONTROLLER_CAPABILITIES: string[] = [CONTROLLER_CAPABILITY_MAKER_EVENT_BATCH_V1];
export const MAKER_EVENT_BATCH_CHANNEL = 'maker:event:batch';

/**
 * 微批只接收同一 sessionId 的原 maker:event payload；坏项逐条跳过且保持顺序。
 */
export function expandMakerEventBatchPayload(payload: Object | undefined): Record<string, Object>[] {
  if (payload === undefined || payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
    return [];
  }
  const batch = payload as Record<string, Object>;
  const sessionId = batch['sessionId'];
  const events = batch['events'];
  if (typeof sessionId !== 'string' || sessionId.length === 0
    || !Array.isArray(events) || events.length === 0) return [];
  const out: Record<string, Object>[] = [];
  const rows = events as Object[];
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    if (row === undefined || row === null || typeof row !== 'object' || Array.isArray(row)) continue;
    const event = row as Record<string, Object>;
    if (event['sessionId'] === sessionId) out.push(event);
  }
  return out;
}

/** topic：'sessions' 或 'session:<id>'。 */
export function sessionTopic(sessionId: string): string {
  return `session:${sessionId}`;
}

export const SESSIONS_TOPIC = 'sessions';
