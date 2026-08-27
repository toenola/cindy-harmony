/**
 * 生成状态的跨端投影。
 *
 * Mobile 会把 maker status 里的 outputTokens / generationDurationMs 与宽运行态分开
 * 保存：只有服务端明确声明 generationActive 且 generationReliable 时才显示 tok/s；
 * 否则最多展示累计输出 token，不用本地墙钟时间伪造速率。
 */

export class SessionGenerationStatus {
  isRunning: boolean = false;
  status: string = '';
  outputTokens: number = 0;
  generationDurationMs: number = 0;
  generationActive: boolean = false;
  generationReliable: boolean = true;
}

function finiteMetric(data: Record<string, Object>, key: string): number | undefined {
  const value = data[key];
  if (typeof value !== 'number' || !Number.isFinite(value)) return undefined;
  return Math.max(0, value);
}

function hasMetric(data: Record<string, Object>, key: string): boolean {
  return finiteMetric(data, key) !== undefined;
}

function copyStatus(source: SessionGenerationStatus): SessionGenerationStatus {
  const copy = new SessionGenerationStatus();
  copy.isRunning = source.isRunning;
  copy.status = source.status;
  copy.outputTokens = source.outputTokens;
  copy.generationDurationMs = source.generationDurationMs;
  copy.generationActive = source.generationActive;
  copy.generationReliable = source.generationReliable;
  return copy;
}

/** 宽运行态从上一轮切到新一轮时，先清掉上一轮残留的实时指标。 */
export function resetGenerationMetricsForNewTurn(
  source: SessionGenerationStatus,
): SessionGenerationStatus {
  const next = copyStatus(source);
  next.outputTokens = 0;
  next.generationDurationMs = 0;
  next.generationActive = false;
  next.generationReliable = true;
  return next;
}

/**
 * 应用一条 maker status。
 *
 * `isTurnStart` 使用 maker 自己的 false→true 边界，而不是宽 session running；这样
 * activity/重连快照先到时仍能清理旧一轮。provider 续跑边界只结束 SDK 段，不能清空
 * 产品级回合的实时状态。
 */
export function applyGenerationStatusEvent(
  source: SessionGenerationStatus,
  data: Record<string, Object>,
  isRunning: boolean | undefined,
  isTurnStart: boolean,
  hasTurnContinuation: boolean,
): SessionGenerationStatus {
  const current = copyStatus(source);
  if (isRunning === undefined) return current;

  if (!isRunning && hasTurnContinuation) {
    current.isRunning = true;
    return current;
  }

  const rawOutputTokens = finiteMetric(data, 'outputTokens');
  const rawGenerationDurationMs = finiteMetric(data, 'generationDurationMs');
  const hasLiveFields = hasMetric(data, 'outputTokens')
    || hasMetric(data, 'generationDurationMs')
    || typeof data['generationActive'] === 'boolean'
    || typeof data['generationReliable'] === 'boolean';

  current.isRunning = isRunning;
  if (rawOutputTokens !== undefined) {
    current.outputTokens = rawOutputTokens;
  } else if (isTurnStart) {
    current.outputTokens = 0;
  }
  if (rawGenerationDurationMs !== undefined) {
    current.generationDurationMs = rawGenerationDurationMs;
  } else if (isTurnStart) {
    current.generationDurationMs = 0;
  }
  if (typeof data['generationActive'] === 'boolean') {
    current.generationActive = data['generationActive'] as boolean;
  } else if (!isRunning) {
    current.generationActive = false;
  } else if (isTurnStart || hasLiveFields) {
    // 收到一组实时字段但服务端没有明确 active 时，不能把它猜成正在生成。
    current.generationActive = false;
  }
  if (typeof data['generationReliable'] === 'boolean') {
    current.generationReliable = data['generationReliable'] as boolean;
  } else if (isTurnStart) {
    current.generationReliable = true;
  }
  const rawStatus = data['status'];
  if (typeof rawStatus === 'string' && rawStatus.length > 0) current.status = rawStatus;
  return current;
}

function compactMetric(value: number): string {
  if (value >= 1000000) {
    const result = (value / 1000000).toFixed(value >= 10000000 ? 1 : 2);
    return `${result.endsWith('.0') ? result.slice(0, -2) : result}M`;
  }
  if (value >= 1000) {
    const result = (value / 1000).toFixed(value >= 10000 ? 1 : 2);
    return `${result.endsWith('.0') ? result.slice(0, -2) : result}K`;
  }
  return `${Math.floor(value)}`;
}

function compactRate(value: number): string {
  if (value >= 100) return `${Math.round(value)}`;
  const digits = value >= 10 ? 1 : 2;
  const result = value.toFixed(digits);
  return result.endsWith('.0') ? result.slice(0, -2) : result;
}

/**
 * 返回附加到“生成中”的短状态；空字符串表示没有可靠的实时或累计数据，调用方
 * 应继续展示既有运行状态/时长。
 */
export function generationStatusLabel(status: SessionGenerationStatus): string {
  if (!status.isRunning) return '';
  if (status.generationActive && status.generationReliable
    && status.outputTokens > 0 && status.generationDurationMs > 0) {
    const seconds = status.generationDurationMs / 1000;
    return `${compactRate(status.outputTokens / seconds)} tok/s`;
  }
  if (status.outputTokens > 0) return `${compactMetric(status.outputTokens)} tokens`;
  return '';
}
