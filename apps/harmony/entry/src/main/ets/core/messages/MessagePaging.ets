import { safeErrorMessage } from '../tasks/TaskModels';

/** 仅帧体过大时降页；连接、权限等错误必须立即交给 UI。 */
export function isPayloadTooLargeError(error: Object | undefined): boolean {
  if (error !== null && typeof error === 'object') {
    const record = error as Record<string, Object>;
    if (record['code'] === 'PAYLOAD_TOO_LARGE') return true;
  }
  const message = safeErrorMessage(error);
  return message.indexOf('PAYLOAD_TOO_LARGE') >= 0 || /frame exceeds \d+ bytes/i.test(message);
}

export function historyRetryLimits(initial: number): number[] {
  const start = Math.max(1, Math.floor(initial));
  const out: number[] = [start];
  let current = start;
  while (current > 1) {
    if (current > 25) current = Math.floor(current / 2);
    else if (current > 10) current = 10;
    else if (current > 5) current = 5;
    else current = 1;
    if (out[out.length - 1] !== current) out.push(current);
  }
  return out;
}

/**
 * 一次真实分页请求已经返回后，入口只服从这一页的连续性信号。短页 / 空页代表
 * 已到历史起点；任务总数随后增长可能只是尾部新增，不能反向点亮顶部入口。
 */
export function shouldKeepOlderMessagesAffordance(
  pageItemCount: number,
  pageHasMore: boolean,
): boolean {
  return pageItemCount > 0 && pageHasMore;
}

/** 总数只用于真实分页尚未落地的缓存窗口，不能覆盖已经收口的分页结论。 */
export function shouldInferOlderMessagesFromCount(
  pagingAvailabilityResolved: boolean,
  totalCount: number,
  loadedRealCount: number,
): boolean {
  return !pagingAvailabilityResolved && totalCount > loadedRealCount;
}
