/** 模型选择器的账号额度：每台电脑、每个来源读一次，再按模型桶投影。 */
import { ComposerModelOption } from '../ComposerCatalog';
import { readNum, readObj, readStr, recordOrEmpty } from '../tasks/TaskModels';
import { selectUsageBucket } from './AccountUsage';

export class ModelPickerQuota {
  key: string = '';
  source: string = '';
  identity: string = '';
  raw: Object | undefined = undefined;
}

function sourceOf(option: ComposerModelOption): string {
  if (!option.subscription && !option.openAiSubscription) return '';
  if (option.providerId === 'openai') return 'codex';
  if (option.providerId === 'anthropic') return 'claude';
  if (option.providerId === 'xai') return 'xai';
  return '';
}

export function modelQuotaKey(deviceId: string, option: ComposerModelOption): string {
  return JSON.stringify([option.agentDeviceId || deviceId, option.providerId]);
}

export async function readModelPickerQuotas(
  deviceId: string,
  options: ComposerModelOption[],
  invoke: (target: string, channel: string, args: Object[]) => Promise<Object | undefined>,
): Promise<ModelPickerQuota[]> {
  const sources = new Map<string, ComposerModelOption>();
  for (const option of options) {
    if (sourceOf(option) && option.providerId) sources.set(modelQuotaKey(deviceId, option), option);
  }
  const values: ModelPickerQuota[] = [];
  for (const key of sources.keys()) {
    const option = sources.get(key);
    if (option === undefined) continue;
    const source = sourceOf(option);
    const target = option.agentDeviceId || deviceId;
    const value = new ModelPickerQuota();
    value.key = key;
    value.source = source;
    try {
      if ((option.providerId === 'openai' && source === 'codex')
        || (option.providerId === 'anthropic' && source === 'claude')) {
        const request: Record<string, Object> = {};
        request['action'] = 'read';
        request['providerId'] = option.providerId;
        const pool = recordOrEmpty(await invoke(target, 'maker:subscription-accounts', [request]));
        if (readStr(pool, 'providerId') !== option.providerId || !Array.isArray(pool['accounts'])) continue;
        const accounts = pool['accounts'] as Object[];
        const bound = readStr(pool, 'boundAccountId');
        let chosen: Record<string, Object> | null = null;
        for (const raw of accounts) {
          const account = recordOrEmpty(raw);
          if (bound && readStr(account, 'id') === bound) { chosen = account; break; }
          if (!bound && accounts.length === 1) chosen = account;
        }
        // 未绑定且有多个账号时不把某一个账号的额度冒充当前账号。
        if (chosen === null) continue;
        value.identity = readStr(chosen, 'identity');
        const usage = readObj(chosen, 'usage');
        if (source === 'claude') value.raw = usage['claude'];
        else {
          const buckets = readObj(readObj(usage, 'codex'), 'buckets');
          const codex: Record<string, Object> = {};
          codex['rateLimitsByLimitId'] = buckets;
          const firstBucket = Object.values(buckets)[0];
          codex['rateLimits'] = buckets['codex'] ?? firstBucket ?? new Object();
          value.raw = codex;
        }
      } else {
        const channel = source === 'codex' ? 'maker:usage:codex-rate-limits'
          : `maker:usage:${source}-subscription`;
        const raw = await invoke(target, channel, [option.providerId]);
        const returnedProvider = readStr(recordOrEmpty(raw), 'providerId');
        if (returnedProvider && returnedProvider !== option.providerId) continue;
        value.raw = raw;
      }
      values.push(value);
    } catch (_error) {
      // 额度不可用时隐藏本行额度，不显示 0%。
    }
  }
  return values;
}

export function modelQuotaLine(option: ComposerModelOption, deviceId: string,
  values: ModelPickerQuota[], now: number = Date.now()): string {
  const source = sourceOf(option);
  if (!source) return '';
  const quota = values.find((value: ModelPickerQuota) => value.key === modelQuotaKey(deviceId, option));
  if (quota === undefined || quota.raw === undefined) return '';
  const root = recordOrEmpty(quota.raw);
  let used = NaN;
  let reset = NaN;
  if (source === 'codex') {
    const bucket = selectUsageBucket(readObj(root, 'rateLimitsByLimitId'), option.id, now)
      ?? readObj(root, 'rateLimits');
    const primary = readObj(bucket, 'primary');
    const secondary = readObj(bucket, 'secondary');
    const emptyWeekly: Record<string, Object> = {};
    const weekly: Record<string, Object> = readNum(primary, 'windowMinutes', 0) === 10080 ? primary
      : (readNum(secondary, 'windowMinutes', 0) === 10080 ? secondary : emptyWeekly);
    used = readNum(weekly, 'usedPercent', NaN);
    reset = readNum(weekly, 'resetsAt', NaN);
  } else if (source === 'claude') {
    const weekly = readObj(root, 'sevenDay');
    used = readNum(weekly, 'utilization', NaN);
    reset = readNum(weekly, 'resetsAt', NaN);
  } else {
    if (now - readNum(root, 'updatedAt', 0) > 30 * 60 * 1000) return '';
    used = readNum(root, 'creditUsagePercent', NaN);
    reset = readNum(root, 'resetsAt', NaN);
  }
  if (!Number.isFinite(used) || (Number.isFinite(reset) && reset * 1000 <= now)) return '';
  const remaining = Math.round(Math.max(0, Math.min(100, 100 - used)));
  const resetText = Number.isFinite(reset) && reset > 0
    ? ` · ${new Date(reset * 1000).toLocaleString()} 重置` : '';
  return `${quota.identity ? quota.identity + ' · ' : ''}剩余 ${remaining}%${resetText}`;
}
