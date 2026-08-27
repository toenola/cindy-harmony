import { RemoteMessage, readBool, isAgentTaskTerminalStatus } from '../tasks/TaskModels';

export class MessageWindowCoverage {
  since: number = 0;
  until: number = 0;
  liveTailTrusted: boolean = false;
}

export class LatestWindowReconcileResult {
  items: RemoteMessage[] = [];
  coverage: MessageWindowCoverage | null = null;
}

function identity(message: RemoteMessage): string {
  if (message.id.length > 0) return `id:${message.id}`;
  if (message.clientId.length > 0) return `client:${message.clientId}`;
  return `fallback:${message.role}:${message.createdAt}:${message.rowid}`;
}

function createdMs(message: RemoteMessage): number {
  const value = Date.parse(message.createdAt);
  return Number.isFinite(value) ? value : 0;
}

function isLocalSystemMessage(message: RemoteMessage): boolean {
  return message.id.startsWith('mobile-system-') || message.id.startsWith('harmony-system-');
}

function pageCanJoinCoverage(
  existing: RemoteMessage[],
  latest: RemoteMessage[],
  coverage: MessageWindowCoverage,
  pageOldest: number,
): boolean {
  if (coverage.since <= 0 || coverage.until <= 0 || pageOldest > coverage.until) return false;
  const existingIds = new Set<string>();
  for (let i = 0; i < existing.length; i++) existingIds.add(identity(existing[i]));
  for (let i = 0; i < latest.length; i++) {
    const timestamp = createdMs(latest[i]);
    if (timestamp >= coverage.since && timestamp <= coverage.until
      && !existingIds.has(identity(latest[i]))) return false;
  }
  return true;
}

function preferExistingCompleteRow(existing: RemoteMessage, latest: RemoteMessage): boolean {
  return readBool(latest.agentMeta, 'remoteContentTruncated', false)
    && !readBool(existing.agentMeta, 'remoteContentTruncated', false);
}

function applyAgentTaskStatus(
  existing: RemoteMessage | undefined,
  incoming: RemoteMessage,
  selected: RemoteMessage,
  preferIncoming: boolean,
): void {
  const existingStatus = existing?.agentTaskStatus ?? '';
  const incomingStatus = incoming.agentTaskStatus;
  const status = preferIncoming
    ? (incomingStatus.length > 0 ? incomingStatus : existingStatus)
    : (existingStatus.length > 0 ? existingStatus : incomingStatus);
  if (!isAgentTaskTerminalStatus(status)) return;
  selected.agentTaskStatus = status;
  selected.agentMeta['agentTaskStatus'] = status;
}

/**
 * 最新页只为自己和已验证相接的旧段背书；满页/裁页时丢弃来源不明的历史孤岛。
 */
export function reconcileLatestMessageWindow(
  existing: RemoteMessage[],
  latest: RemoteMessage[],
  moreBeyondWindow: boolean,
  previousCoverage: MessageWindowCoverage | null,
  liveTailTrusted: boolean,
): LatestWindowReconcileResult {
  const result = new LatestWindowReconcileResult();
  if (latest.length === 0) {
    for (let i = 0; i < existing.length; i++) {
      if (isLocalSystemMessage(existing[i]) || existing[i].isStreaming) {
        result.items.push(existing[i]);
      }
    }
    return result;
  }
  let pageOldest = 0;
  let pageNewest = 0;
  const latestIds = new Set<string>();
  const existingById = new Map<string, RemoteMessage>();
  for (let i = 0; i < existing.length; i++) existingById.set(identity(existing[i]), existing[i]);
  for (let i = 0; i < latest.length; i++) {
    latestIds.add(identity(latest[i]));
    const timestamp = createdMs(latest[i]);
    if (timestamp <= 0) continue;
    if (pageOldest <= 0 || timestamp < pageOldest) pageOldest = timestamp;
    if (timestamp > pageNewest) pageNewest = timestamp;
  }
  let hasOverlap = false;
  latestIds.forEach((key: string) => {
    if (existingById.has(key)) hasOverlap = true;
  });
  const verifiedJoin = previousCoverage !== null && pageOldest > 0
    && pageCanJoinCoverage(existing, latest, previousCoverage, pageOldest);

  const byId = new Map<string, RemoteMessage>();
  for (let i = 0; i < latest.length; i++) {
    const key = identity(latest[i]);
    const existingRow = existingById.get(key);
    const keepExisting = existingRow !== undefined && preferExistingCompleteRow(existingRow, latest[i]);
    const selected: RemoteMessage = keepExisting && existingRow !== undefined
      ? existingRow : latest[i];
    applyAgentTaskStatus(existingRow, latest[i], selected, !keepExisting);
    byId.set(key, selected);
  }
  for (let i = 0; i < existing.length; i++) {
    const message = existing[i];
    const key = identity(message);
    if (byId.has(key)) continue;
    const timestamp = createdMs(message);
    const keepVerifiedOld = verifiedJoin && previousCoverage !== null
      && timestamp >= previousCoverage.since && timestamp < pageOldest;
    const keepLegacyOld = !moreBeyondWindow && hasOverlap && timestamp > 0 && timestamp < pageOldest;
    // Mobile 保留与最新页尾行同毫秒、但 identity 不同的实时消息；毫秒时间戳并不唯一。
    const keepLiveTail = pageNewest > 0 && timestamp >= pageNewest;
    if (keepVerifiedOld || keepLegacyOld || keepLiveTail
      || isLocalSystemMessage(message) || message.isStreaming) byId.set(key, message);
  }
  byId.forEach((message: RemoteMessage) => result.items.push(message));

  if (pageOldest > 0 && pageNewest > 0) {
    const coverage = new MessageWindowCoverage();
    coverage.since = verifiedJoin && previousCoverage !== null
      ? Math.min(previousCoverage.since, pageOldest) : pageOldest;
    coverage.until = verifiedJoin && previousCoverage !== null
      ? Math.max(previousCoverage.until, pageNewest) : pageNewest;
    coverage.liveTailTrusted = liveTailTrusted;
    result.coverage = coverage;
  }
  return result;
}

export function extendCoverageEarlier(
  coverage: MessageWindowCoverage | null,
  rows: RemoteMessage[],
  joinsAt: RemoteMessage | null = null,
): MessageWindowCoverage | null {
  if (rows.length === 0) return coverage;
  let oldest = coverage?.since ?? 0;
  for (let i = 0; i < rows.length; i++) {
    const timestamp = createdMs(rows[i]);
    if (timestamp > 0 && (oldest <= 0 || timestamp < oldest)) oldest = timestamp;
  }
  if (oldest <= 0) return coverage;
  if (coverage !== null) {
    coverage.since = oldest;
    return coverage;
  }
  if (joinsAt === null) return null;
  const joinTimestamp = createdMs(joinsAt);
  if (joinTimestamp <= 0 || oldest > joinTimestamp) return null;
  const created = new MessageWindowCoverage();
  created.since = oldest;
  created.until = joinTimestamp;
  created.liveTailTrusted = false;
  return created;
}

export function extendCoverageLiveTail(
  coverage: MessageWindowCoverage | null,
  message: RemoteMessage,
): void {
  if (coverage === null || !coverage.liveTailTrusted) return;
  const timestamp = createdMs(message);
  if (timestamp > coverage.until) coverage.until = timestamp;
}
