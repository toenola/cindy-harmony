/**
 * 任务页宽屏双栏布局的纯计算。
 *
 * 600vp 对齐 Mobile 的 medium 窗口档位；只有展开态横屏才使用主从双栏，
 * 竖屏、盒盖态和半折叠态都回到单页导航。比例只约束列表宽度，分隔条和详情
 * 最小宽度固定留出触控与阅读空间。
 */

export const WIDE_TASK_LAYOUT_MIN_WIDTH = 600;
export const TASK_SPLIT_DIVIDER_WIDTH = 20;
export const TASK_SPLIT_MIN_LIST_WIDTH = 220;
export const TASK_SPLIT_MIN_DETAIL_WIDTH = 320;
export const TASK_SPLIT_DEFAULT_RATIO = 1 / 3;
export const TASK_SPLIT_MIN_RATIO = 0.25;
export const TASK_SPLIT_MAX_RATIO = 0.6;
export const TASK_FOLD_STATUS_EXPANDED = 1;
export const TASK_FOLD_STATUS_FOLDED = 2;
export const TASK_FOLD_STATUS_HALF_FOLDED = 3;

/**
 * 独立详情页转入宽屏双栏时，先把当前任务交还给仍在路由栈中的列表页。
 * 这是一次性内存交接，不持久化，也不会覆盖用户之后在列表中的选择。
 */
export class TaskSplitRouteSelection {
  deviceId: string = '';
  sessionId: string = '';
  messageClientId: string = '';
}

let pendingTaskSplitRouteSelection: TaskSplitRouteSelection | null = null;

export function handoffTaskSplitRouteSelection(
  deviceId: string,
  sessionId: string,
  messageClientId: string = '',
): void {
  const selection = new TaskSplitRouteSelection();
  selection.deviceId = deviceId;
  selection.sessionId = sessionId;
  selection.messageClientId = messageClientId;
  pendingTaskSplitRouteSelection = selection;
}

export function consumeTaskSplitRouteSelection(): TaskSplitRouteSelection | null {
  const selection = pendingTaskSplitRouteSelection;
  pendingTaskSplitRouteSelection = null;
  return selection;
}

export function isWideTaskLayout(
  viewportWidth: number,
  viewportHeight: number,
  foldStatus: number = -1,
): boolean {
  const postureSupportsSplit = foldStatus === -1 || foldStatus === TASK_FOLD_STATUS_EXPANDED;
  if (!postureSupportsSplit) {
    return false;
  }
  return Number.isFinite(viewportWidth)
    && Number.isFinite(viewportHeight)
    && viewportHeight > 0
    && viewportWidth > viewportHeight
    && viewportWidth >= WIDE_TASK_LAYOUT_MIN_WIDTH;
}

export function clampTaskSplitRatio(ratio: number): number {
  if (!Number.isFinite(ratio)) return TASK_SPLIT_DEFAULT_RATIO;
  return Math.min(TASK_SPLIT_MAX_RATIO, Math.max(TASK_SPLIT_MIN_RATIO, ratio));
}

export function taskListPaneWidth(viewportWidth: number, ratio: number): number {
  if (!Number.isFinite(viewportWidth) || viewportWidth <= 0) return 0;
  const availableWidth = Math.max(0, viewportWidth - TASK_SPLIT_DIVIDER_WIDTH);
  const minListWidth = Math.min(TASK_SPLIT_MIN_LIST_WIDTH, availableWidth);
  const maxListWidth = Math.max(minListWidth, availableWidth - TASK_SPLIT_MIN_DETAIL_WIDTH);
  const requestedWidth = Math.round(availableWidth * clampTaskSplitRatio(ratio));
  return Math.min(maxListWidth, Math.max(minListWidth, requestedWidth));
}

export function taskSplitRatioForDrag(
  viewportWidth: number,
  startRatio: number,
  deltaX: number,
): number {
  if (!Number.isFinite(viewportWidth) || viewportWidth <= TASK_SPLIT_DIVIDER_WIDTH) {
    return clampTaskSplitRatio(startRatio);
  }
  const availableWidth = viewportWidth - TASK_SPLIT_DIVIDER_WIDTH;
  const nextWidth = taskListPaneWidth(viewportWidth, startRatio) + deltaX;
  return clampTaskSplitRatio(nextWidth / availableWidth);
}

/**
 * 展开屏键盘只占用详情栏的可用高度；列表栏仍保持全高并由键盘覆盖。
 * 窄屏继续交给系统的页面级键盘避让处理。
 */
export function taskDetailKeyboardInset(
  viewportWidth: number,
  viewportHeight: number,
  foldStatus: number,
  keyboardHeight: number,
): number {
  if (!isWideTaskLayout(viewportWidth, viewportHeight, foldStatus)) return 0;
  if (!Number.isFinite(keyboardHeight) || keyboardHeight <= 0) return 0;
  return keyboardHeight;
}
