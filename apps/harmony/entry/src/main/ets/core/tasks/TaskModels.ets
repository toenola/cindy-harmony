/**
 * 远程会话 / 消息模型（ArkTS 版）。
 *
 * 字段与 wire 契约对齐 apps/mobile/src/session/types.ts 的 RemoteSession /
 * RemoteMessage（desktop 端 localDb mapper 产出）。解析时保留原始内容，
 * 不把 Tool / Thinking / 媒体压扁为纯文本（见 docs/message-rendering.md）。
 *
 * 切片 1 只消费列表展示与消息渲染需要的字段子集；其余字段在原始 JSON
 * 中保留，后续切片按需补解析。
 */

// ─── 通用读取 helpers ────────────────────────────────────────────────────────

export function readStr(obj: Record<string, Object>, key: string): string {
  const v = obj[key];
  return typeof v === 'string' ? v : '';
}

export function readNum(obj: Record<string, Object>, key: string, def: number): number {
  const v = obj[key];
  return typeof v === 'number' ? v : def;
}

export function readBool(obj: Record<string, Object>, key: string, def: boolean): boolean {
  const v = obj[key];
  return typeof v === 'boolean' ? v : def;
}

export function readObj(obj: Record<string, Object>, key: string): Record<string, Object> {
  const v = obj[key];
  // JSON 中的可选对象字段可能明确为 null（分支会话的旧消息就是这种形态）。
  // `typeof null === 'object'`，不排除 null 会把它当成 Record，后续读取嵌套
  // 字段时抛出 Cannot load property of null，并导致整条消息被丢弃。
  if (v !== undefined && v !== null && typeof v === 'object' && !Array.isArray(v)) {
    return v as Record<string, Object>;
  }
  return {};
}

/** 任意 JSON 值（消息 content / agentMeta 等，渲染层按类型解释）。 */
export function readAny(obj: Record<string, Object>, key: string): Object | undefined {
  const v = obj[key];
  // 可选 JSON 字段的 null 与缺省值在消息渲染模型中语义相同；保留 null
  // 会让 contentPreview / parseUserContent 把 null 误判成对象。
  return v === undefined || v === null ? undefined : (v as Object);
}

// ─── 设备 ────────────────────────────────────────────────────────────────────

/** REST /api/device-link/devices 的设备视图（对齐 DeviceView）。 */
export class DeviceView {
  deviceId: string = '';
  name: string = '';
  platform: string = '';
  appVersion: string = '';
  online: boolean = false;
  busy: boolean = false;
  remoteControlEnabled: boolean = false;
  /** unix ms；从未上线的离线设备可能为 0。 */
  lastSeenAt: number = 0;
  isSelf: boolean = false;
}

export function parseDeviceView(raw: Record<string, Object>): DeviceView {
  const v = new DeviceView();
  v.deviceId = readStr(raw, 'deviceId');
  v.name = readStr(raw, 'name');
  v.platform = readStr(raw, 'platform');
  v.appVersion = readStr(raw, 'appVersion');
  v.online = readBool(raw, 'online', false);
  v.busy = readBool(raw, 'busy', false);
  v.remoteControlEnabled = readBool(raw, 'remoteControlEnabled', false);
  v.isSelf = readBool(raw, 'isSelf', false);
  // lastSeenAt 是 ISO 字符串（离线未上线可能为 null）。
  const rawSeen = readStr(raw, 'lastSeenAt');
  if (rawSeen.length > 0) {
    const ts = Date.parse(rawSeen);
    v.lastSeenAt = Number.isNaN(ts) ? 0 : ts;
  }
  return v;
}

// ─── 会话 ────────────────────────────────────────────────────────────────────

export class RemoteSession {
  id: string = '';
  userId: string = '';
  title: string = '';
  workingDir: string = '';
  workspaceKind: string = 'project';
  model: string = '';
  /** 当前模型显式使用的供应商来源；空值表示跟随主机默认路由。 */
  providerId: string = '';
  effort: string = '';
  permissionMode: string = '';
  planModeEnabled: boolean = false;
  fastMode: boolean = false;
  status: string = 'active'; // 'active' | 'archived' | 'deleted'
  /** 'cc' | 'codex' | 'pi'（被控端 mapper 透出） */
  agentKind: string = '';
  source: string = '';
  orcaRole: string = '';
  pinnedAt: string = '';
  userSendAt: string = '';
  createdAt: string = '';
  updatedAt: string = '';
  preview: string = '';
  messageCount: number = 0;
}

export function parseSession(raw: Record<string, Object>): RemoteSession {
  const s = new RemoteSession();
  s.id = readStr(raw, 'id');
  s.userId = readStr(raw, 'userId');
  s.title = readStr(raw, 'title');
  s.workingDir = readStr(raw, 'workingDir');
  s.workspaceKind = readStr(raw, 'workspaceKind');
  if (s.workspaceKind.length === 0) s.workspaceKind = 'project';
  s.model = readStr(raw, 'model');
  s.providerId = readStr(raw, 'providerId');
  s.effort = readStr(raw, 'effort');
  s.permissionMode = readStr(raw, 'permissionMode');
  s.planModeEnabled = readBool(raw, 'planModeEnabled', false);
  s.fastMode = readBool(raw, 'fastMode', false);
  s.status = readStr(raw, 'status');
  if (s.status.length === 0) s.status = 'active';
  s.agentKind = readStr(raw, 'agentKind');
  s.source = readStr(raw, 'source');
  s.orcaRole = readStr(raw, 'orcaRole');
  s.pinnedAt = readStr(raw, 'pinnedAt');
  s.userSendAt = readStr(raw, 'userSendAt');
  s.createdAt = readStr(raw, 'createdAt');
  s.updatedAt = readStr(raw, 'updatedAt');
  s.preview = readStr(raw, 'preview');
  const count = readObj(raw, '_count');
  s.messageCount = readNum(count, 'messages', 0);
  return s;
}

// ─── 消息 ────────────────────────────────────────────────────────────────────

export class RemoteMessage {
  id: string = '';
  clientId: string = '';
  sessionId: string = '';
  rowid: number = 0;
  role: string = '';
  /** 原始内容（string | 结构化对象），渲染层按 role 解释，不做无损降级。 */
  content: Object | undefined = undefined;
  toolUseId: string = '';
  createdAt: string = '';
  systemCardType: string = '';
  systemCardData: Record<string, Object> = {};
  /** agentMeta 中的 turn seal；用于区分过程正文与最终答复。 */
  turnCompleted: boolean = false;
  /** 流式投影标记；历史正文不应被当作最终答复展示。 */
  isStreaming: boolean = false;
  /** 保留少量 agentMeta 语义，避免渲染层只能靠消息顺序猜测 turn。 */
  agentMeta: Record<string, Object> = {};
  /** 自动化任务注入的消息（agentMeta.origin 非空）——折叠阈值更紧。 */
  automationOrigin: boolean = false;
}

export function parseMessage(raw: Record<string, Object>): RemoteMessage {
  const m = new RemoteMessage();
  m.id = readStr(raw, 'id');
  m.clientId = readStr(raw, 'clientId');
  m.sessionId = readStr(raw, 'sessionId');
  m.rowid = readNum(raw, 'rowid', 0);
  m.role = readStr(raw, 'role');
  m.content = readAny(raw, 'content');
  m.toolUseId = readStr(raw, 'toolUseId');
  m.systemCardType = readStr(raw, 'systemCardType');
  m.systemCardData = readObj(raw, 'systemCardData');
  // 自动化注入消息：仅接受 scheduler origin 的完整结构，和 Mobile
  // readAutomationOrigin 同源；其它 origin 不能误用自动化的 4 行收起阈值。
  const agentMeta = readObj(raw, 'agentMeta');
  m.agentMeta = agentMeta;
  const turnUsageDetails = readObj(agentMeta, 'turnUsageDetails');
  const turnCost = readObj(agentMeta, 'turnCost');
  m.turnCompleted = readBool(raw, 'turnCompleted', false)
    || readBool(agentMeta, 'turnCompleted', false)
    || Object.keys(turnUsageDetails).length > 0
    || Object.keys(turnCost).length > 0
    || readNum(agentMeta, 'turnCostUsd', 0) > 0;
  m.isStreaming = readBool(raw, 'isStreaming', false)
    || readBool(agentMeta, 'isStreaming', false)
    || readBool(agentMeta, 'streaming', false);
  if (m.content !== undefined && m.content !== null
    && typeof m.content === 'object' && !Array.isArray(m.content)) {
    const content = m.content as Record<string, Object>;
    m.isStreaming = m.isStreaming
      || readBool(content, 'isStreaming', false)
      || readBool(content, 'streaming', false);
  }
  const origin = readObj(agentMeta, 'origin');
  m.automationOrigin = readStr(origin, 'kind') === 'scheduler'
    && readStr(origin, 'scheduleId').length > 0;
  // createdAt 两种形态都要兼容：
  // - history:messages 返回 DB 原始 integer（unix ms，见 desktop chatHistoryReader
  //   `createdAt: r.m.createdAt`）；
  // - messages:created push 的消息行走 messageToCamel，返回 ISO 字符串。
  // 统一转 ISO 字符串，保证 sortMessagesAsc 的字符串比较正确。
  m.createdAt = readStr(raw, 'createdAt');
  if (m.createdAt.length === 0) {
    const ts = readNum(raw, 'createdAt', 0);
    if (ts > 0) {
      m.createdAt = new Date(ts).toISOString();
    }
  }
  return m;
}

/** 按 createdAt 升序排序（稳定排序 + rowid 兜底）。 */
export function sortMessagesAsc(a: RemoteMessage, b: RemoteMessage): number {
  if (a.createdAt !== b.createdAt) {
    if (a.createdAt < b.createdAt) return -1;
    if (a.createdAt > b.createdAt) return 1;
  }
  return a.rowid - b.rowid;
}

export function sortSessionsByUpdatedAt(a: RemoteSession, b: RemoteSession): number {
  if (a.updatedAt === b.updatedAt) return 0;
  return a.updatedAt > b.updatedAt ? -1 : 1;
}
