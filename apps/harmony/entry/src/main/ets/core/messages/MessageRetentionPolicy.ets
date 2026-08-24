/**
 * 消息驻留与内存预算策略（纯逻辑）。
 *
 * 语义对齐 Mobile 事实源：
 * - `apps/mobile/src/session/sessionRetention.ts`：驻留类型只由 `session.source`
 *   决定，`source` 缺失一律按普通任务处理。**禁止用标题或 schedule 索引猜测**：
 *   标题可变、schedule 绑定既有任务时不改写 source，猜错会误回收用户任务。
 * - `apps/mobile/src/session/remoteSessionStore.ts`：普通任务全局预算
 *   800 行 / 64 MiB（先达者为准），字节数用稳定近似估算；LRU 只释放内存对象，
 *   持久快照删除是独立决策，不得绑定执行。
 *
 * 工作租约优先于 LRU：本地系统卡、乐观用户消息、未收敛流式行等**没有服务端副本**
 * 的内容一旦被淘汰就不可恢复，因此含保护行的会话整窗跳过淘汰。
 */

import { RemoteMessage, RemoteSession } from '../tasks/TaskModels';

/** 自动化任务只保留一个最新窗口；普通任务参与全局预算竞争。 */
export const RETENTION_REGULAR = 'regular';
export const RETENTION_SCHEDULE = 'schedule';

/** 普通任务全局预算：先达到者为准（对齐 Mobile 常量）。 */
export const REGULAR_GLOBAL_MESSAGE_ROW_BUDGET = 800;
export const REGULAR_GLOBAL_MESSAGE_BYTES_BUDGET = 64 * 1024 * 1024;
/** 每行固定结构开销的近似值；避免在热路径反复全量序列化。 */
export const MESSAGE_STRUCTURAL_BYTES_ESTIMATE = 512;

/**
 * 驻留分类只认权威 `source` 字段。
 *
 * 传入 undefined（任务快照尚未到达）时保守按普通任务处理：宁可多驻留，
 * 也不能因为晚到信息把用户任务误回收。
 */
export function classifySessionRetention(session: RemoteSession | undefined): string {
  return session !== undefined && session.source === 'scheduler'
    ? RETENTION_SCHEDULE : RETENTION_REGULAR;
}

/** 稳定、可测试的字节近似：只统计可变长内容，结构开销取固定值。 */
export function estimateMessageBytes(message: RemoteMessage): number {
  let bytes = MESSAGE_STRUCTURAL_BYTES_ESTIMATE;
  bytes += stringifiedLength(message.content) * 2;
  if (Object.keys(message.agentMeta).length > 0) {
    bytes += stringifiedLength(message.agentMeta) * 2;
  }
  if (Object.keys(message.systemCardData).length > 0) {
    bytes += stringifiedLength(message.systemCardData) * 2;
  }
  return bytes;
}

function stringifiedLength(value: Object | undefined): number {
  if (value === undefined || value === null) return 0;
  if (typeof value === 'string') return (value as string).length;
  try {
    return JSON.stringify(value).length;
  } catch (e) {
    return 0;
  }
}

export function estimateMessageRowsBytes(messages: RemoteMessage[]): number {
  let total = 0;
  for (let i = 0; i < messages.length; i++) total += estimateMessageBytes(messages[i]);
  return total;
}

/**
 * 该行是否属于受保护的本地工作集。
 *
 * 这些行没有服务端副本或尚未落库，淘汰后不可重取：本地系统卡、乐观用户消息
 * （无 id）、本地流式行。保护行的存在会让整个会话退出 LRU 候选——保留部分行
 * 反而可能被缓存写回误当成完整窗口，覆盖磁盘上更新的一页。
 */
export function isProtectedMessageRow(message: RemoteMessage): boolean {
  if (message.localOnly) return true;
  const id = message.id;
  if (id.length === 0) return true;
  return id.startsWith('mobile-system-')
    || id.startsWith('harmony-system-')
    || id.startsWith('streaming-');
}

export function hasProtectedMessageRow(messages: RemoteMessage[]): boolean {
  for (let i = 0; i < messages.length; i++) {
    if (isProtectedMessageRow(messages[i])) return true;
  }
  return false;
}

/** 参与全局预算计算的单个会话快照。 */
export class RetentionCandidate {
  sessionId: string = '';
  retention: string = RETENTION_REGULAR;
  rowCount: number = 0;
  bytes: number = 0;
  /** 最近访问序号；越小越旧。 */
  accessOrder: number = 0;
  /** 当前订阅中或持有可见/后台工作租约，不参与淘汰。 */
  leased: boolean = false;
  /** 含无服务端副本的本地行，整窗跳过淘汰。 */
  hasProtectedRows: boolean = false;
}

/**
 * 选出应从内存中淘汰的普通任务会话（按 LRU），直到回到预算内。
 *
 * 只考虑普通任务：自动化任务不参与全局预算，由单窗口策略约束。
 * 返回的是**内存淘汰**决定；调用方不得据此删除持久快照。
 */
export function selectRegularBudgetEvictions(candidates: RetentionCandidate[]): string[] {
  let totalRows = 0;
  let totalBytes = 0;
  const evictable: RetentionCandidate[] = [];
  for (let i = 0; i < candidates.length; i++) {
    const candidate = candidates[i];
    if (candidate.retention !== RETENTION_REGULAR) continue;
    totalRows += candidate.rowCount;
    totalBytes += candidate.bytes;
    if (candidate.leased || candidate.hasProtectedRows) continue;
    evictable.push(candidate);
  }
  if (withinRegularBudget(totalRows, totalBytes)) return [];
  evictable.sort((a: RetentionCandidate, b: RetentionCandidate) => a.accessOrder - b.accessOrder);
  const victims: string[] = [];
  for (let i = 0; i < evictable.length; i++) {
    if (withinRegularBudget(totalRows, totalBytes)) break;
    victims.push(evictable[i].sessionId);
    totalRows -= evictable[i].rowCount;
    totalBytes -= evictable[i].bytes;
  }
  return victims;
}

function withinRegularBudget(rows: number, bytes: number): boolean {
  return rows <= REGULAR_GLOBAL_MESSAGE_ROW_BUDGET
    && bytes <= REGULAR_GLOBAL_MESSAGE_BYTES_BUDGET;
}

/**
 * 实时 push 的 authority fence。
 *
 * push 只有在设备身份与当前缓存 / 订阅一致时才允许写入：快速 A → B → A 切换时，
 * B 的实时帧会在 A 重新打开后才到达，若无此判定就会把 B 的内容写进 A 的窗口。
 *
 * - 该会话尚无任何设备归属（首次 push 早于历史加载）：接受并由调用方登记归属；
 * - 已有订阅设备：必须与订阅设备一致；
 * - 无订阅但有缓存归属：必须与缓存归属一致（后台会话仍可接收自己设备的更新）。
 */
export function pushAuthorityAccepted(
  pushDeviceId: string,
  subscribedDeviceId: string,
  cachedDeviceId: string,
): boolean {
  if (pushDeviceId.length === 0) return false;
  if (subscribedDeviceId.length > 0) return pushDeviceId === subscribedDeviceId;
  if (cachedDeviceId.length > 0) return pushDeviceId === cachedDeviceId;
  return true;
}

/**
 * 软窗口裁剪：保护行全部保留，剩余额度给最新的服务端行。
 *
 * 保护行较多时允许略超上限——数据安全优先于精确条数（对齐 Mobile trimMessageWindow）。
 * 返回新数组；未超限时返回原内容的副本，调用方可直接比较是否需要写回。
 */
export function trimMessageWindow(messages: RemoteMessage[], limit: number): RemoteMessage[] {
  if (messages.length <= limit) return messages.slice();
  const protectedRows: RemoteMessage[] = [];
  const evictableRows: RemoteMessage[] = [];
  for (let i = 0; i < messages.length; i++) {
    if (isProtectedMessageRow(messages[i])) protectedRows.push(messages[i]);
    else evictableRows.push(messages[i]);
  }
  const keepEvictable = Math.max(0, limit - protectedRows.length);
  const kept = evictableRows.slice(Math.max(0, evictableRows.length - keepEvictable));
  // 保持原有相对顺序：按原数组重扫一遍，命中保留集合的行按序输出。
  const keptKeys = new Set<RemoteMessage>();
  for (let i = 0; i < protectedRows.length; i++) keptKeys.add(protectedRows[i]);
  for (let i = 0; i < kept.length; i++) keptKeys.add(kept[i]);
  const out: RemoteMessage[] = [];
  for (let i = 0; i < messages.length; i++) {
    if (keptKeys.has(messages[i])) out.push(messages[i]);
  }
  return out;
}
