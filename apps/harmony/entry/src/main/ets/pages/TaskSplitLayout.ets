/**
 * 任务页宽屏双栏布局的纯计算。
 *
 * 600vp 对齐 Mobile 的 medium 窗口档位，覆盖折叠屏展开内屏和大屏横向窗口；
 * 盒盖态/直板机保持单页列表导航。比例只约束列表宽度，分隔条和详情最小宽度
 * 固定留出触控与阅读空间。
 */

export const WIDE_TASK_LAYOUT_MIN_WIDTH = 600;
export const TASK_SPLIT_DIVIDER_WIDTH = 20;
export const TASK_SPLIT_MIN_LIST_WIDTH = 220;
export const TASK_SPLIT_MIN_DETAIL_WIDTH = 320;
export const TASK_SPLIT_DEFAULT_RATIO = 1 / 3;
export const TASK_SPLIT_MIN_RATIO = 0.25;
export const TASK_SPLIT_MAX_RATIO = 0.6;
export const TASK_FOLD_STATUS_FOLDED = 2;
export const TASK_FOLD_STATUS_HALF_FOLDED = 3;

export function isWideTaskLayout(viewportWidth: number, foldStatus: number = -1): boolean {
  if (foldStatus === TASK_FOLD_STATUS_FOLDED || foldStatus === TASK_FOLD_STATUS_HALF_FOLDED) {
    return false;
  }
  return Number.isFinite(viewportWidth) && viewportWidth >= WIDE_TASK_LAYOUT_MIN_WIDTH;
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
