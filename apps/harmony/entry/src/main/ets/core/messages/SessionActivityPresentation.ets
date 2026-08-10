/** 会话底部活动条的纯展示逻辑；与工作组自身的 duration/startedAt 相互独立。 */

export function sessionActivityElapsedMs(nowMs: number, startedAtMs: number): number {
  if (!Number.isFinite(nowMs) || !Number.isFinite(startedAtMs) || startedAtMs <= 0) return 0;
  return Math.max(0, nowMs - startedAtMs);
}

/** iOS 活动条从 0s 起跳并向下取整；工作组历史时长继续使用原有四舍五入口径。 */
export function formatSessionActivityElapsed(elapsedMs: number): string {
  const safeMs = Number.isFinite(elapsedMs) ? Math.max(0, elapsedMs) : 0;
  const seconds = Math.floor(safeMs / 1000);
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  return minutes > 0 ? `${minutes}m ${rest}s` : `${rest}s`;
}
