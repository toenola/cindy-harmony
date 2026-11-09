/**
 * 任务页宽屏双栏布局的纯计算。
 *
 * 窗口与安全区共同决定是否分栏，不依赖设备折叠状态或横竖屏。
 * 系统分屏与悬浮窗一律单栏（D-015，Harmony 有意差异）。
 * 列表标题的四个操作需要保留 300vp；分隔条不占布局宽度。
 */

export const WIDE_TASK_LAYOUT_MIN_WIDTH = 600;
export const WIDE_TASK_LAYOUT_MIN_SAFE_WIDTH = 760;
export const WIDE_TASK_LAYOUT_MIN_SAFE_HEIGHT = 480;
export const TASK_SPLIT_DIVIDER_WIDTH = 20;
/** 容纳设备下拉、四个头部操作按钮和底部导航，不允许控件彼此覆盖。 */
export const TASK_SPLIT_MIN_LIST_WIDTH = 300;
export const TASK_SPLIT_MIN_DETAIL_WIDTH = 400;
export const TASK_SPLIT_MAX_LIST_WIDTH = 420;
/** `window.WindowStatusType` 中的悬浮窗与分屏取值。 */
export const TASK_WINDOW_STATUS_FLOATING = 4;
export const TASK_WINDOW_STATUS_SPLIT_SCREEN = 5;

/** 系统分屏或悬浮窗：窗口只占屏幕一部分，即使尺寸达标也不分栏。 */
export function taskWindowIsMultiWindow(status: number): boolean {
  return status === TASK_WINDOW_STATUS_FLOATING || status === TASK_WINDOW_STATUS_SPLIT_SCREEN;
}

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
  safeWidth: number,
  safeHeight: number,
  multiWindow: boolean = false,
): boolean {
  return !multiWindow
    && Number.isFinite(viewportWidth)
    && Number.isFinite(safeWidth)
    && Number.isFinite(safeHeight)
    && viewportWidth >= WIDE_TASK_LAYOUT_MIN_WIDTH
    && safeWidth >= WIDE_TASK_LAYOUT_MIN_SAFE_WIDTH
    && safeHeight >= WIDE_TASK_LAYOUT_MIN_SAFE_HEIGHT;
}

export class TaskSafeWindowSize {
  width: number = 0;
  height: number = 0;
}

/**
 * 分栏判断使用的安全区尺寸。窗口避让区明确读不到时退回页面尺寸，不能让双栏永久不可用；
 * 仍在读取时保持 0，避免冷启动先进入双栏、拿到真实安全区后又退出并触发单栏跳转。
 * 高度不与页面高度取较小值：输入法会压缩页面高度，不能因此在输入时收起双栏。
 */
export function effectiveTaskSafeWindow(
  viewportWidth: number,
  viewportHeight: number,
  safeWidth: number,
  safeHeight: number,
  metricsUnavailable: boolean,
): TaskSafeWindowSize {
  const size = new TaskSafeWindowSize();
  size.width = metricsUnavailable ? viewportWidth : Math.min(viewportWidth, safeWidth);
  size.height = metricsUnavailable ? viewportHeight : safeHeight;
  return size;
}

export function taskListPaneWidth(viewportWidth: number, requestedWidth: number = 0): number {
  if (!Number.isFinite(viewportWidth) || viewportWidth <= 0) return 0;
  const minListWidth = Math.min(TASK_SPLIT_MIN_LIST_WIDTH, viewportWidth);
  const maxListWidth = Math.max(minListWidth, Math.min(TASK_SPLIT_MAX_LIST_WIDTH,
    viewportWidth - TASK_SPLIT_MIN_DETAIL_WIDTH));
  const preferred = Number.isFinite(requestedWidth) && requestedWidth > 0
    ? requestedWidth : Math.min(320, Math.round(viewportWidth * 0.34));
  return Math.round(Math.min(maxListWidth, Math.max(minListWidth, preferred)));
}

/**
 * 详情栏必须显式吃满列表栏以外的全部宽度。
 * HdsNavigation 嵌套在 Row 的 layoutWeight 子节点时可能回退到内容固有宽度，
 * 因此不能只依赖权重分配，否则大屏右侧会残留一块空白窗口背景。
 */
export function taskDetailPaneWidth(viewportWidth: number, requestedWidth: number = 0): number {
  if (!Number.isFinite(viewportWidth) || viewportWidth <= 0) return 0;
  return Math.max(
    0,
    viewportWidth - taskListPaneWidth(viewportWidth, requestedWidth),
  );
}

export function taskSplitWidthForDrag(
  viewportWidth: number,
  startWidth: number,
  deltaX: number,
): number {
  return taskListPaneWidth(viewportWidth, Math.max(1, taskListPaneWidth(viewportWidth, startWidth) + deltaX));
}

/**
 * 展开屏键盘只占用详情栏的可用高度；列表栏仍保持全高并由键盘覆盖。
 * 窄屏继续交给系统的页面级键盘避让处理。
 */
export function taskDetailKeyboardInset(
  viewportWidth: number,
  safeWidth: number,
  safeHeight: number,
  keyboardHeight: number,
  multiWindow: boolean = false,
): number {
  if (!isWideTaskLayout(viewportWidth, safeWidth, safeHeight, multiWindow)) return 0;
  if (!Number.isFinite(keyboardHeight) || keyboardHeight <= 0) return 0;
  return keyboardHeight;
}

export class TaskHeaderTitleInsets {
  left: number = 0;
  right: number = 0;
}

/**
 * 会话详情标题居中（D-015）。左右按钮组宽度不同：标题放得下时两侧都按较宽一组留白，
 * 严格对准标题栏中线；放不下时改为填满两组按钮之间的空间并由省略号截断，
 * 不为了居中把标题挤到几乎不可见。宽度单位均为 vp，gap 是标题与按钮组的间距。
 */
export function taskHeaderTitleInsets(
  barWidth: number,
  leadingWidth: number,
  trailingWidth: number,
  titleWidth: number,
  gap: number,
): TaskHeaderTitleInsets {
  const insets = new TaskHeaderTitleInsets();
  const leading = Math.max(0, leadingWidth) + gap;
  const trailing = Math.max(0, trailingWidth) + gap;
  const side = Math.max(leading, trailing);
  if (Number.isFinite(barWidth) && Number.isFinite(titleWidth) && titleWidth <= barWidth - side * 2) {
    insets.left = side;
    insets.right = side;
  } else {
    insets.left = leading;
    insets.right = trailing;
  }
  return insets;
}
