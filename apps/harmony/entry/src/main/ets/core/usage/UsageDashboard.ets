/** Mobile UsageDashboard / usageWidgetSync projection. Read-only desktop snapshot, no vendor calls. */
import { DlClient, DlInvokeOptions } from '../device-link/DlClient';
import { PresenceSnapshot } from '../device-link/DlProtocol';
import { unwrapInvokeResult } from '../tasks/TaskStore';
import { readNum, readObj, readStr, recordOrEmpty } from '../tasks/TaskModels';

export class UsageSource {
  id: string = '';
  kind: string = '';
  name: string = '';
  logo: string = '';
  monogram: string = '';
  value: string = '';
  unit: string = '';
  label: string = '';
  level: string = '';
  fill: number = 0;
  reserve: boolean = false;
  emphasized: boolean = false;
  when: string = '';
  resetsAtMs: number = 0;
  stale: boolean = false;
}
export class UsageDay {
  date: string = '';
  tokens: number[] = [];
  money: number[] = [];
  paid: number = 0;
  modelTokens: number[] = [];
  modelCount: number = 0;
}
export class UsageSnapshot {
  generatedAtMs: number = 0;
  updatedAtMs: number = 0;
  moneySymbol: string = '';
  scope: string = '';
  sources: UsageSource[] = [];
  days: UsageDay[] = [];
  models: string[] = [];
  strings: Record<string, Object> = {};
}
export class UsageSeries {
  name: string = '';
  colorIndex: number = 0;
  values: number[] = [];
  total: number = 0;
  other: boolean = false;
}
export function usageSum(values: number[]): number {
  return values.reduce((sum: number, value: number): number => sum + value, 0);
}
function nonnegative(value: number): number {
  return Number.isFinite(value) ? Math.max(0, value) : 0;
}
function numbers(value: Object | undefined): number[] {
  if (!Array.isArray(value)) return [];
  return (value as Object[]).slice(0, 65).map((item: Object): number =>
    typeof item === 'number' ? nonnegative(item as number) : 0);
}
/** Missing snapshots are unavailable, never a fabricated zero balance. */
export function parseUsageSnapshot(value: Object | undefined): UsageSnapshot | null {
  const root = recordOrEmpty(value);
  const usage = readObj(root, 'usage');
  if (root['version'] !== 1 || !Array.isArray(root['sources'])
    || !Array.isArray(usage['daily']) || !Array.isArray(usage['days'])) return null;
  const out = new UsageSnapshot();
  out.generatedAtMs = nonnegative(readNum(root, 'generatedAtMs', 0));
  out.updatedAtMs = nonnegative(readNum(root, 'updatedAtMs', 0));
  out.moneySymbol = readStr(root, 'moneySymbol');
  out.scope = readStr(usage, 'scope');
  out.strings = readObj(root, 'strings');
  (root['sources'] as Object[]).slice(0, 64).forEach((value: Object): void => {
    const raw = recordOrEmpty(value);
    if (raw['kind'] !== 'subscription' && raw['kind'] !== 'balance') return;
    const item = new UsageSource();
    item.id = readStr(raw, 'id'); item.kind = readStr(raw, 'kind');
    item.name = readStr(raw, 'name'); item.logo = readStr(raw, 'logo');
    item.monogram = readStr(raw, 'monogram'); item.value = readStr(raw, 'value');
    item.unit = readStr(raw, 'unit'); item.label = readStr(raw, 'label');
    item.level = readStr(raw, 'level'); item.fill = Math.min(1, nonnegative(readNum(raw, 'fill', 0)));
    item.when = readStr(raw, 'when'); item.resetsAtMs = nonnegative(readNum(raw, 'resetsAtMs', 0));
    item.reserve = raw['reserve'] === true; item.emphasized = raw['emphasized'] === true;
    item.stale = raw['stale'] === true;
    out.sources.push(item);
  });
  if (Array.isArray(usage['models'])) {
    out.models = (usage['models'] as Object[]).slice(0, 64).map((model: Object): string =>
      readStr(recordOrEmpty(model), 'name'));
  }
  const daily = usage['daily'] as Object[];
  const dates = usage['days'] as Object[];
  const start = Math.max(0, daily.length - 30);
  for (let i = start; i < daily.length; i++) {
    const raw = recordOrEmpty(daily[i]);
    const day = new UsageDay();
    day.date = typeof dates[i] === 'string' ? dates[i] as string : '';
    day.tokens = numbers(raw['tokens']); day.money = numbers(raw['money']);
    day.paid = nonnegative(readNum(raw, 'paid', 0));
    day.modelTokens = numbers(raw['modelTokens']); day.modelCount = numbers(raw['models']).length;
    out.days.push(day);
  }
  return out;
}

/** Same bucket choice / top-three + other merge as Mobile, shared by chart and legend. */
export function usageSeries(snapshot: UsageSnapshot, other: string): UsageSeries[] {
  const modelMode = snapshot.models.length > 0 && snapshot.days.every((day: UsageDay): boolean =>
    day.modelCount === snapshot.models.length + 1 && day.modelTokens.length === snapshot.models.length + 1);
  const names = modelMode ? snapshot.models.concat([other]) : ['Codex', 'Claude Code', 'Pi'];
  const indices = modelMode ? names.map((_name: string, i: number): number => i) : [1, 0, 2];
  const all: UsageSeries[] = [];
  names.forEach((name: string, index: number): void => {
    const series = new UsageSeries();
    series.name = name; series.colorIndex = index;
    series.other = modelMode && index === snapshot.models.length;
    series.values = snapshot.days.map((day: UsageDay): number =>
      (modelMode ? day.modelTokens : day.tokens)[indices[index]] ?? 0);
    series.total = usageSum(series.values);
    if (series.total > 0) all.push(series);
  });
  if (all.length <= 4) return all;
  const kept = all.filter((series: UsageSeries): boolean => !series.other)
    .sort((a: UsageSeries, b: UsageSeries): number => b.total - a.total).slice(0, 3);
  const rest = all.filter((series: UsageSeries): boolean => !kept.includes(series));
  const merged = new UsageSeries(); merged.name = other; merged.other = true; merged.colorIndex = 5;
  merged.values = snapshot.days.map((_day: UsageDay, i: number): number =>
    rest.reduce((sum: number, series: UsageSeries): number => sum + series.values[i], 0));
  merged.total = usageSum(merged.values);
  return all.filter((series: UsageSeries): boolean => kept.includes(series)).concat([merged]);
}
export function usageCompact(value: number): string {
  const n = nonnegative(value);
  const sizes = [1e9, 1e6, 1e3]; const units = ['B', 'M', 'K'];
  for (let i = 0; i < sizes.length; i++) {
    if (n >= sizes[i]) return (n / sizes[i]).toFixed(1).replace(/\.0$/, '') + units[i];
  }
  return Math.round(n).toLocaleString();
}
export function usageResetLabel(source: UsageSource, strings: Record<string, Object>, now: number,
  expired: string): string {
  if (source.stale || !source.resetsAtMs) return source.when;
  const left = source.resetsAtMs - now;
  if (left <= 0) return expired;
  const minutes = Math.max(1, Math.floor(left / 60000));
  const d = Math.floor(minutes / 1440), h = Math.floor(minutes % 1440 / 60), m = minutes % 60;
  const key = d ? (h ? 'daysHours' : 'days') : h ? (m ? 'hoursMinutes' : 'hours') : 'minutes';
  const template = readStr(strings, 'durationShort.' + key);
  if (!template) return source.when;
  const duration = template.replace('{{d}}', String(d)).replace('{{h}}', String(h)).replace('{{m}}', String(m));
  return readStr(strings, 'resetsIn').replace('{{duration}}', duration) || duration;
}
export class UsageReadResult {
  snapshot: UsageSnapshot | null = null;
  deviceId: string = '';
  deviceName: string = '';
  issue: string = 'unavailable';
}
export function usageCandidates(devices: PresenceSnapshot[], preferred: string, pinned: string = ''): PresenceSnapshot[] {
  const rank = (device: PresenceSnapshot): number =>
    device.deviceId === preferred ? 0 : device.platform === 'darwin' ? 1 : 2;
  return devices.filter((device: PresenceSnapshot): boolean => device.online && device.remoteControlEnabled
    && (device.platform === 'darwin' || device.platform === 'win32' || device.platform === 'linux')
    && (!pinned || device.deviceId === pinned))
    .sort((a: PresenceSnapshot, b: PresenceSnapshot): number => rank(a) - rank(b));
}
/** Sequential fallback only until one computer answers; no polling or broadcast fan-out. */
export async function readUsageDashboard(client: DlClient, devices: PresenceSnapshot[], preferred: string,
  isCurrent: () => boolean, pinned: string = ''): Promise<UsageReadResult> {
  const result = new UsageReadResult();
  const candidates = usageCandidates(devices, preferred, pinned);
  if (!candidates.length) { result.issue = 'offline'; return result; }
  let tooOld = 0;
  for (const device of candidates) {
    if (!isCurrent()) return result;
    try {
      const options = new DlInvokeOptions();
      options.channel = 'device-link:usage-widget:snapshot:v1'; options.args = [];
      const envelope = await client.invoke(device.deviceId, options);
      if (!isCurrent()) return result;
      const raw = recordOrEmpty(unwrapInvokeResult(envelope));
      const snapshot = raw['ok'] === true ? parseUsageSnapshot(raw['snapshot']) : null;
      if (snapshot !== null) {
        result.snapshot = snapshot; result.deviceId = device.deviceId;
        result.deviceName = device.selfName || device.deviceName; result.issue = ''; return result;
      }
    } catch (error) {
      if (String(error).includes('CHANNEL_NOT_ALLOWED')) tooOld++;
    }
  }
  if (tooOld === candidates.length) {
    result.issue = 'unsupported';
    result.deviceId = candidates[0].deviceId;
  }
  return result;
}
