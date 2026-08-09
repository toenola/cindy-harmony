import { RemoteMessage } from '../tasks/TaskModels';

/**
 * 与 Mobile `historyWindowGap.ts` 同源的历史窗口空洞判定。
 *
 * 时间跳变本身不等于缺消息，所以这里只负责找候选；MessageStore 会先用
 * `limit=1` 探测两侧在服务端是否本来相邻，再沿既有 before 游标补齐。
 */
export const HISTORY_GAP_SPLIT_MS = 30 * 60 * 1000;
export const HISTORY_BACKFILL_MAX_ROWS = 400;
export const HISTORY_BACKFILL_MAX_REQUESTS = 12;
export const HISTORY_BACKFILL_MAX_GAPS_PER_VISIT = 3;
export const HISTORY_GAP_MAX_CONSIDERED_PER_VISIT = 6;
export const HISTORY_GAP_PROBE_MAX_STEPS = 8;

export class HistoryWindowGap {
  newerId: string = '';
  olderId: string = '';
  newerMs: number = 0;
  olderMs: number = 0;
  gapMs: number = 0;
}

class HistoryGapRow {
  id: string = '';
  rowid: number = 0;
  ms: number = 0;
}

/** 本地合成卡和流式投影不能充当 Desktop before 游标。 */
export function isHostHistoryRow(message: RemoteMessage): boolean {
  return message.id.length > 0
    && !message.id.startsWith('mobile-system-')
    && !message.id.startsWith('harmony-system-')
    && !message.id.startsWith('streaming-');
}

/** 从消息尾部向前找尚未探测过的时间跳变。 */
export function findHistoryWindowGap(
  messages: RemoteMessage[],
  consideredGapKeys: Set<string>,
): HistoryWindowGap | null {
  const rows: HistoryGapRow[] = [];
  for (let i = 0; i < messages.length; i++) {
    const message = messages[i];
    if (!isHostHistoryRow(message)) continue;
    const ms = Date.parse(message.createdAt);
    if (!Number.isFinite(ms)) continue;
    const row = new HistoryGapRow();
    row.id = message.id;
    row.rowid = message.rowid;
    row.ms = ms;
    rows.push(row);
  }
  rows.sort((a: HistoryGapRow, b: HistoryGapRow) => {
    if (a.ms !== b.ms) return a.ms - b.ms;
    if (a.rowid !== b.rowid) return a.rowid - b.rowid;
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  });
  for (let i = rows.length - 1; i > 0; i--) {
    const newer = rows[i];
    const older = rows[i - 1];
    const gapMs = newer.ms - older.ms;
    if (gapMs <= HISTORY_GAP_SPLIT_MS) continue;
    const gap = new HistoryWindowGap();
    gap.newerId = newer.id;
    gap.olderId = older.id;
    gap.newerMs = newer.ms;
    gap.olderMs = older.ms;
    gap.gapMs = gapMs;
    if (!consideredGapKeys.has(historyWindowGapKey(gap))) return gap;
  }
  return null;
}

/** 同毫秒消息的 id 次序不稳定，因此空洞身份只使用两侧时刻。 */
export function historyWindowGapKey(gap: HistoryWindowGap): string {
  return `${gap.olderMs}→${gap.newerMs}`;
}

/** 按服务端 desc 返回顺序取页尾真实 host 行。 */
export function historyPageTailCursor(page: RemoteMessage[]): string {
  for (let i = page.length - 1; i >= 0; i--) {
    if (isHostHistoryRow(page[i])) return page[i].id;
  }
  return '';
}

/** 页尾 host 行的时刻；不可解析时返回 -1。 */
export function historyPageTailMs(page: RemoteMessage[]): number {
  for (let i = page.length - 1; i >= 0; i--) {
    if (!isHostHistoryRow(page[i])) continue;
    const ms = Date.parse(page[i].createdAt);
    return Number.isFinite(ms) ? ms : -1;
  }
  return -1;
}

export function historyPageCoversMs(page: RemoteMessage[], targetMs: number): boolean {
  for (let i = 0; i < page.length; i++) {
    const ms = Date.parse(page[i].createdAt);
    if (Number.isFinite(ms) && ms <= targetMs) return true;
  }
  return false;
}
