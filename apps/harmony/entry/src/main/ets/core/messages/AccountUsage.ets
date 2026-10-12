/** Account quota projection follows Mobile; never represents per-task spend. */
import { readNum, readObj, readStr, recordOrEmpty } from '../tasks/TaskModels';

export class AccountUsageSummary {
  source: string = 'unavailable';
  providerLabel: string = '';
  plan: string = '';
  updatedAt: number = 0;
  lines: string[] = [];
}

function bucketTable(value: Object | undefined): Record<string, Object> {
  const input = recordOrEmpty(value);
  const result: Record<string, Object> = {};
  for (const key of Object.keys(input)) {
    if (key === '__proto__' || key === 'constructor' || key === 'prototype') continue;
    const entry = input[key];
    if (entry !== null && typeof entry === 'object' && !Array.isArray(entry)) result[key] = entry;
  }
  return result;
}

function bucketStale(value: Record<string, Object>, now: number): boolean {
  const windows: Record<string, Object>[] = [];
  for (const name of ['primary', 'secondary']) {
    if (value[name] !== null && typeof value[name] === 'object') windows.push(readObj(value, name));
  }
  if (windows.length === 0) return false;
  let latest = 0;
  for (const window of windows) {
    const resets = readNum(window, 'resetsAt', 0);
    if (!Number.isFinite(resets) || resets <= 0) return false;
    latest = Math.max(latest, resets);
  }
  return latest * 1000 + 86400000 < now;
}

export function selectUsageBucket(table: Record<string, Object>, model: string, now: number): Record<string, Object> | null {
  const token = model.toLowerCase().replace(/[^a-z0-9]/g, '');
  let selected: Record<string, Object> | null = null;
  let longest = 0;
  for (const key of Object.keys(table)) {
    const bucket = recordOrEmpty(table[key]);
    if (bucketStale(bucket, now)) continue;
    const name = readStr(bucket, 'limitName').toLowerCase().replace(/[^a-z0-9]/g, '');
    if (token && name && token === name) return bucket;
    if (token && name && token.indexOf(name) >= 0 && name.length > longest) {
      selected = bucket; longest = name.length;
    }
  }
  if (selected !== null) return selected;
  for (const key of ['codex', '__default__']) {
    if (table[key] !== undefined) {
      const bucket = recordOrEmpty(table[key]);
      if (!bucketStale(bucket, now)) return bucket;
    }
  }
  return null;
}

export function projectAccountUsage(raw: Object | undefined, source: string, model: string,
  now: number = Date.now(),
  text: (key: string, args: string[]) => string = (key: string, args: string[]): string => [key, ...args].join(' ')): AccountUsageSummary {
  const root = recordOrEmpty(raw);
  const result = new AccountUsageSummary();
  result.source = source;
  if (source === 'gateway') {
    result.updatedAt = readNum(root, 'fetchedAt', 0);
    const currency = readStr(root, 'currency');
    if (currency !== 'CNY' && currency !== 'USD') return result;
    const spend = readNum(root, 'spend', NaN);
    const limit = readNum(root, 'maxBudget', NaN);
    const today = readNum(root, 'todaySpend', NaN);
    if (Number.isFinite(spend) && spend >= 0 && Number.isFinite(limit) && limit > 0) {
      result.lines.push(text('v131_usage_period', [spend.toFixed(2), limit.toFixed(2), currency]));
    }
    if (Number.isFinite(today) && today >= 0) result.lines.push(text('v131_usage_today', [today.toFixed(2), currency]));
    return result;
  }
  const fallback = root['rateLimits'] === undefined ? root : readObj(root, 'rateLimits');
  let table = bucketTable(root['rateLimitsByLimitId']);
  if (Object.keys(table).length === 0) table = bucketTable(fallback['appServerBuckets']);
  const generic = Object.keys(table).length > 0 ? selectUsageBucket(table, '', now) : fallback;
  const specific = Object.keys(table).length > 0 ? selectUsageBucket(table, model, now) : fallback;
  const snapshots: Record<string, Object>[] = [];
  if (generic !== null) snapshots.push(generic);
  if (specific !== null && specific !== generic) snapshots.push(specific);
  result.plan = readStr(readObj(root, 'account'), 'planType');
  for (const snapshot of snapshots) {
    const time = readNum(snapshot, 'updatedAt', readNum(fallback, 'updatedAt', now));
    if (Number.isFinite(time) && time > 0) result.updatedAt = result.updatedAt > 0 ? Math.min(result.updatedAt, time) : time;
    const plan = readStr(snapshot, 'planType');
    if (plan) result.plan = plan;
    const label = snapshot === generic ? '' : (readStr(snapshot, 'limitName') || model) + ' · ';
    for (const name of ['primary', 'secondary']) {
      const window = readObj(snapshot, name);
      const used = readNum(window, 'usedPercent', NaN);
      const resets = readNum(window, 'resetsAt', NaN);
      if (!Number.isFinite(used) || (Number.isFinite(resets) && resets * 1000 <= now)) continue;
      const minutes = readNum(window, 'windowMinutes', 0);
      const duration = minutes > 0 ? text('v131_usage_minutes', [String(minutes)])
        : text(name === 'primary' ? 'v131_usage_primary' : 'v131_usage_secondary', []);
      result.lines.push(label + text('v131_usage_remaining', [duration, `${Math.max(0, Math.min(100, 100 - used)).toFixed(0)}%`])
        + (Number.isFinite(resets) ? ' · ' + text('v131_usage_reset', [new Date(resets * 1000).toLocaleString()]) : ''));
    }
  }
  return result;
}
