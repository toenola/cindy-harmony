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

export function recordOrEmpty(value: Object | null | undefined): Record<string, Object> {
  if (value !== undefined && value !== null && typeof value === 'object' && !Array.isArray(value)) {
    return value as Record<string, Object>;
  }
  return {};
}

export function readStr(obj: Record<string, Object> | null | undefined, key: string): string {
  if (obj === undefined || obj === null) return '';
  const v = obj[key];
  return typeof v === 'string' ? v : '';
}

export function readNum(obj: Record<string, Object> | null | undefined, key: string, def: number): number {
  if (obj === undefined || obj === null) return def;
  const v = obj[key];
  return typeof v === 'number' ? v : def;
}

export function readBool(obj: Record<string, Object> | null | undefined, key: string, def: boolean): boolean {
  if (obj === undefined || obj === null) return def;
  const v = obj[key];
  return typeof v === 'boolean' ? v : def;
}

export function readObj(
  obj: Record<string, Object> | null | undefined,
  key: string,
): Record<string, Object> {
  if (obj === undefined || obj === null) return {};
  // JSON 中的可选对象字段可能明确为 null（分支会话的旧消息就是这种形态）。
  // `typeof null === 'object'`，不排除 null 会把它当成 Record，后续读取嵌套
  // 字段时抛出 Cannot load property of null，并导致整条消息被丢弃。
  return recordOrEmpty(obj[key]);
}

/** 任意 JSON 值（消息 content / agentMeta 等，渲染层按类型解释）。 */
export function readAny(obj: Record<string, Object> | null | undefined, key: string): Object | undefined {
  if (obj === undefined || obj === null) return undefined;
  const v = obj[key];
  // 可选 JSON 字段的 null 与缺省值在消息渲染模型中语义相同；保留 null
  // 会让 contentPreview / parseUserContent 把 null 误判成对象。
  return v === undefined || v === null ? undefined : (v as Object);
}

/**
 * 将远端/系统抛出的值安全转换为诊断文本。
 *
 * Device Link 旧端可能直接 reject `undefined`，某些系统错误还可能带有
 * 循环引用；错误处理路径不能因为再次 JSON.stringify 失败而掩盖原始失败。
 */
export function safeErrorMessage(error: Object | undefined): string {
  try {
    if (error instanceof Error) return error.message;
    const serialized = JSON.stringify(error);
    return typeof serialized === 'string' ? serialized : '';
  } catch (_error) {
    return '';
  }
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
  worktreePath: string = '';
  extraDirs: string[] = [];
  /** SSH 会话的被控端 host alias；本地会话为空。 */
  remoteHostId: string = '';
  workspaceKind: string = 'project';
  model: string = '';
  /** 当前模型显式使用的供应商来源；空值表示跟随主机默认路由。 */
  providerId: string = '';
  effort: string = '';
  permissionMode: string = '';
  planModeEnabled: boolean = false;
  fastMode: boolean = false;
  /** Desktop SDK thread id；输入队列 lazy-create 时必须透传以保留上下文。 */
  sdkSessionId: string = '';
  totalTokenUsage: number = 0;
  contextTokens: number = 0;
  contextWindow: number = 0;
  status: string = 'active'; // 'active' | 'archived' | 'deleted'
  /** 'cc' | 'codex' | 'pi'（被控端 mapper 透出） */
  agentKind: string = '';
  source: string = '';
  orcaRole: string = '';
  parentSessionId: string = '';
  pinnedAt: string = '';
  userSendAt: string = '';
  createdAt: string = '';
  updatedAt: string = '';
  clearedAt: string = '';
  activeTurnStartedAt: number = 0;
  lastTurnEndedAt: number = 0;
  preview: string = '';
  messageCount: number = 0;
  /** 控制端预生成、首条 enqueue 尚未落定；期间详情页禁止普通远端同步与后续发送。 */
  pendingLocalCreation: boolean = false;
}

export function parseSession(raw: Record<string, Object>): RemoteSession {
  const s = new RemoteSession();
  s.id = readStr(raw, 'id');
  s.userId = readStr(raw, 'userId');
  s.title = readStr(raw, 'title');
  s.workingDir = readStr(raw, 'workingDir');
  s.worktreePath = readStr(raw, 'worktreePath');
  const rawExtraDirs = raw['extraDirs'];
  if (Array.isArray(rawExtraDirs)) {
    const values = rawExtraDirs as Object[];
    for (let i = 0; i < values.length; i++) {
      if (typeof values[i] === 'string') s.extraDirs.push(values[i] as string);
    }
  }
  s.remoteHostId = readStr(raw, 'remoteHostId');
  s.workspaceKind = readStr(raw, 'workspaceKind');
  if (s.workspaceKind.length === 0) s.workspaceKind = 'project';
  s.model = readStr(raw, 'model');
  s.providerId = readStr(raw, 'providerId');
  s.effort = readStr(raw, 'effort');
  s.permissionMode = readStr(raw, 'permissionMode');
  s.planModeEnabled = readBool(raw, 'planModeEnabled', false);
  s.fastMode = readBool(raw, 'fastMode', false);
  s.sdkSessionId = readStr(raw, 'sdkSessionId');
  s.totalTokenUsage = readNum(raw, 'totalTokenUsage', 0);
  s.contextTokens = readNum(raw, 'contextTokens', 0);
  s.contextWindow = readNum(raw, 'contextWindow', 0);
  s.status = readStr(raw, 'status');
  if (s.status.length === 0) s.status = 'active';
  s.agentKind = readStr(raw, 'agentKind');
  s.source = readStr(raw, 'source');
  s.orcaRole = readStr(raw, 'orcaRole');
  s.parentSessionId = readStr(raw, 'parentSessionId');
  s.pinnedAt = readStr(raw, 'pinnedAt');
  s.userSendAt = readStr(raw, 'userSendAt');
  s.createdAt = readStr(raw, 'createdAt');
  s.updatedAt = readStr(raw, 'updatedAt');
  s.clearedAt = readStr(raw, 'clearedAt');
  s.activeTurnStartedAt = readNum(raw, 'activeTurnStartedAt', 0);
  s.lastTurnEndedAt = readNum(raw, 'lastTurnEndedAt', 0);
  s.preview = readStr(raw, 'preview');
  s.pendingLocalCreation = readBool(raw, 'pendingLocalCreation', false);
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
  /** 区分协议缺失与显式 false；Codex 失败印记依赖该三态。 */
  hasTurnCompleted: boolean = false;
  terminalPlanSnapshot: boolean = false;
  terminalPlanAtMs: number = 0;
  /** 流式投影标记；历史正文不应被当作最终答复展示。 */
  isStreaming: boolean = false;
  /** 保留少量 agentMeta 语义，避免渲染层只能靠消息顺序猜测 turn。 */
  agentMeta: Record<string, Object> = {};
  /** Desktop 写入 originating Agent/Task tool_use 的持久终态；历史回放优先于结果文本推断。 */
  agentTaskStatus: string = '';
  /** 自动化任务注入的消息（agentMeta.origin 非空）——折叠阈值更紧。 */
  automationOrigin: boolean = false;
  /** 自动续跑注入行属于 UI 指令；保留 turn 边界，但不能退化成普通用户气泡。 */
  isSyntheticTrigger: boolean = false;
  /** 同一次中断的旧状态行只参与 turn 边界，不进入最终可见列表。 */
  autoResumeHidden: boolean = false;
  /** Hook / Orca worker 虽以 role=user 落库，但来源不是当前用户本人。 */
  presentedAsAgent: boolean = false;
  originLabel: string = '';
  originBody: string = '';
  /** 仅 Harmony 本地反馈卡；远端窗口重载时继续保留。 */
  localOnly: boolean = false;
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
  const metadataAgentTaskStatus = readStr(agentMeta, 'agentTaskStatus');
  const rawAgentTaskStatus = readStr(raw, 'agentTaskStatus');
  m.agentTaskStatus = isAgentTaskTerminalStatus(metadataAgentTaskStatus)
    ? metadataAgentTaskStatus : (isAgentTaskTerminalStatus(rawAgentTaskStatus)
      ? rawAgentTaskStatus : '');
  if (m.role === 'user' && readBool(agentMeta, 'autoResume', false)) {
    const info = readObj(agentMeta, 'autoResumeInfo');
    const data: Record<string, Object> = {};
    const keys = Object.keys(info);
    for (let i = 0; i < keys.length; i++) data[keys[i]] = info[keys[i]];
    const outcome = readStr(agentMeta, 'autoResumeOutcome');
    if (outcome === 'succeeded' || outcome === 'failed') data['outcome'] = outcome;
    m.systemCardType = 'auto-resume';
    m.systemCardData = data;
    m.isSyntheticTrigger = true;
  }
  if (m.systemCardType.length === 0 && m.role === 'assistant') {
    const completion = readObj(agentMeta, 'goalCompletion');
    const notice = readStr(agentMeta, 'goalNotice');
    if (Object.keys(completion).length > 0) {
      m.systemCardType = 'goal-complete';
      m.systemCardData = completion;
    } else if (notice.length > 0) {
      m.systemCardType = 'goal-resumed';
      const data: Record<string, Object> = {};
      data['kind'] = notice;
      m.systemCardData = data;
    }
  }
  if (m.systemCardType.length === 0 && m.role === 'agent_switch') {
    m.systemCardType = 'agent-switch';
    if (m.content !== undefined && typeof m.content === 'object' && !Array.isArray(m.content)) {
      m.systemCardData = m.content as Record<string, Object>;
    }
  }
  if (m.role === 'user') {
    const userText = messageUserText(m.content);
    if (userText.startsWith('[UI_ACTION_TRIGGER]')) m.isSyntheticTrigger = true;
    const hookSource = readObj(agentMeta, 'hookSource');
    const hookIm = readStr(hookSource, 'im');
    if (hookIm === 'slack' || hookIm === 'telegram' || hookIm === 'x') {
      m.presentedAsAgent = true;
      const product = hookIm === 'telegram' ? 'Telegram' : hookIm === 'x' ? 'X' : 'Slack';
      const channel = readStr(hookSource, 'channelName').slice(0, 160);
      m.originLabel = channel.length > 0 ? `Cindy · ${product} · ${channel}` : `Cindy · ${product}`;
      const externalText = readStr(hookSource, 'userText');
      m.originBody = (externalText.length > 0 ? externalText : userText).slice(0, 20000);
    } else if (m.content !== undefined && typeof m.content === 'object' && !Array.isArray(m.content)) {
      const content = m.content as Record<string, Object>;
      if (readStr(content, 'orcaSource') === 'worker') {
        m.presentedAsAgent = true;
        m.originLabel = '协作 Agent';
        const workerContent = content['content'];
        m.originBody = typeof workerContent === 'string'
          ? (workerContent as string).slice(0, 20000)
          : workerContent === undefined ? '' : JSON.stringify(workerContent).slice(0, 20000);
      }
    }
  }
  m.localOnly = readBool(raw, 'localOnly', false);
  const contentRecord = recordOrEmpty(m.content);
  const turnUsageDetails = readObj(agentMeta, 'turnUsageDetails');
  const turnCost = readObj(agentMeta, 'turnCost');
  const rawTurnCompleted = raw['turnCompleted'];
  const metaTurnCompleted = agentMeta['turnCompleted'];
  const contentTurnCompleted = contentRecord['turnCompleted'];
  m.hasTurnCompleted = typeof rawTurnCompleted === 'boolean'
    || typeof metaTurnCompleted === 'boolean'
    || typeof contentTurnCompleted === 'boolean';
  if (typeof rawTurnCompleted === 'boolean') {
    m.turnCompleted = rawTurnCompleted as boolean;
  } else if (typeof metaTurnCompleted === 'boolean') {
    m.turnCompleted = metaTurnCompleted as boolean;
  } else if (typeof contentTurnCompleted === 'boolean') {
    m.turnCompleted = contentTurnCompleted as boolean;
  } else {
    m.turnCompleted = Object.keys(turnUsageDetails).length > 0
      || Object.keys(turnCost).length > 0
      || readNum(agentMeta, 'turnCostUsd', 0) > 0;
  }
  m.terminalPlanSnapshot = readBool(raw, 'terminalPlanSnapshot', false)
    || readBool(agentMeta, 'terminalPlanSnapshot', false)
    || readBool(contentRecord, 'terminalPlanSnapshot', false);
  m.terminalPlanAtMs = readNum(raw, 'terminalPlanAtMs', 0);
  if (m.terminalPlanAtMs <= 0) m.terminalPlanAtMs = readNum(agentMeta, 'terminalPlanAtMs', 0);
  if (m.terminalPlanAtMs <= 0) m.terminalPlanAtMs = readNum(contentRecord, 'terminalPlanAtMs', 0);
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
  // 持久化 turn seal 比遗留 isStreaming 标志更权威；已封口的 assistant 不应
  // 让详情页在重进或滚动后重新显示停止按钮。
  if (m.turnCompleted) {
    m.isStreaming = false;
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

/** 只接受 Desktop 持久化协议定义的终态，未知值继续走历史兼容推断。 */
export function isAgentTaskTerminalStatus(value: string): boolean {
  return value === 'completed' || value === 'failed' || value === 'stopped';
}

/** 合并同一持久消息的终态元数据；正文选择与状态选择相互独立。 */
export function mergeAgentTaskTerminalStatus(
  existing: RemoteMessage,
  incoming: RemoteMessage,
  preferIncoming: boolean = false,
): void {
  if (existing.agentTaskStatus.length === 0 && incoming.agentTaskStatus.length === 0) return;
  let selected = incoming.agentTaskStatus;
  if (existing.agentTaskStatus.length > 0
    && (selected.length === 0 || !preferIncoming)) {
    selected = existing.agentTaskStatus;
  }
  if (!isAgentTaskTerminalStatus(selected)) return;
  incoming.agentTaskStatus = selected;
  incoming.agentMeta['agentTaskStatus'] = selected;
}

function messageUserText(content: Object | undefined): string {
  if (typeof content === 'string') return content;
  if (content !== undefined && content !== null && typeof content === 'object' && !Array.isArray(content)) {
    const record = content as Record<string, Object>;
    const text = record['text'];
    if (typeof text === 'string') return text as string;
    const inner = record['content'];
    if (typeof inner === 'string') return inner as string;
  }
  return '';
}

/**
 * 按 createdAt 升序排序；只有两边都有真实 DB rowid 时才用 rowid 破同毫秒平局。
 * messages:created 实时 push 可能不带 rowid（解析后为 0），此时必须像 Mobile
 * 一样返回 0 保留到达顺序，不能把新正文错误插到旧工作步骤前面。
 */
export function sortMessagesAsc(a: RemoteMessage, b: RemoteMessage): number {
  if (a.createdAt !== b.createdAt) {
    if (a.createdAt < b.createdAt) return -1;
    if (a.createdAt > b.createdAt) return 1;
  }
  if (a.rowid > 0 && b.rowid > 0 && a.rowid !== b.rowid) {
    return a.rowid - b.rowid;
  }
  return 0;
}

export function sortSessionsByUpdatedAt(a: RemoteSession, b: RemoteSession): number {
  if (a.updatedAt === b.updatedAt) return 0;
  return a.updatedAt > b.updatedAt ? -1 : 1;
}
