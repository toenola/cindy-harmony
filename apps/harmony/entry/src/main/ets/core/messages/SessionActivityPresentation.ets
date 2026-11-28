/** 会话底部活动条的纯展示逻辑；与工作组自身的 duration/startedAt 相互独立。 */

export function sessionActivityElapsedMs(nowMs: number, startedAtMs: number): number {
  if (!Number.isFinite(nowMs) || !Number.isFinite(startedAtMs) || startedAtMs <= 0) return 0;
  return Math.max(0, nowMs - startedAtMs);
}

/** iOS 活动条从 0s 起跳并向下取整；工作组历史时长继续使用原有四舍五入口径。 */
export function formatSessionActivityElapsed(elapsedMs: number): string {
  const time = sessionActivityDuration(elapsedMs);
  if (time.days > 0) return `${time.days}d ${time.hours}h ${time.minutes}m`;
  if (time.hours > 0) return `${time.hours}h ${time.minutes}m`;
  return time.minutes > 0 ? `${time.minutes}m ${time.seconds}s` : `${time.seconds}s`;
}

/** Mobile shows turn input + output, not context size or output-only speed. */
export function formatSessionActivityTokens(tokenUsage: number): string {
  const count = Number.isFinite(tokenUsage) ? Math.max(0, Math.round(tokenUsage)) : 0;
  if (count === 0) return '';
  return count >= 1000 ? `${(count / 1000).toFixed(1)}k` : `${count}`;
}

export class SessionActivityRetry {
  phase: string = '';
  progress: string = '';
}

/** Same retry reason and attempt markers consumed by Mobile's maker-event projection. */
export function sessionActivityRetry(message: string, reason: string): SessionActivityRetry {
  const retry = new SessionActivityRetry();
  const rateLimited = reason === 'terminal-rate-limit-retry';
  let match = rateLimited
    ? /\(rate-limit-retry\s+(\d+)\s*\/\s*(\d+)\)\s*$/i.exec(message)
    : /\bReconnecting(?:\.{3}|…)\s*(\d+)\s*\/\s*(\d+)\b/i.exec(message);
  let phase = rateLimited ? 'rate_limit' : 'reconnect';
  if (!rateLimited && match === null) {
    match = /\(auto-retry\s+(\d+)\s*\/\s*(\d+)\)\s*$/i.exec(message);
    phase = 'overload';
  }
  if (match === null) return retry;
  const attempt = Number(match[1]);
  const total = Number(match[2]);
  if (!Number.isSafeInteger(attempt) || !Number.isSafeInteger(total) || attempt < 1 || total < attempt) return retry;
  retry.phase = phase;
  retry.progress = `${attempt}/${total}`;
  return retry;
}

export class SessionActivityDuration {
  days: number = 0;
  hours: number = 0;
  minutes: number = 0;
  seconds: number = 0;
}

export function sessionActivityDuration(elapsedMs: number): SessionActivityDuration {
  const total = Math.floor(Number.isFinite(elapsedMs) ? Math.max(0, elapsedMs) / 1000 : 0);
  const duration = new SessionActivityDuration();
  duration.days = Math.floor(total / 86400);
  duration.hours = Math.floor(total % 86400 / 3600);
  duration.minutes = Math.floor(total % 3600 / 60);
  duration.seconds = total % 60;
  return duration;
}
