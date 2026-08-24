/**
 * 任务列表展示层纯函数。
 *
 * 列表数据仍以被控端 RemoteSession 为真相；这里仅做面向用户的标题、摘要、
 * 项目名称和相对时间投影，避免 ArkUI 页面把展示规则散落在 builder 中。
 */

import { RemoteSession } from '../core/tasks/TaskModels';

const DEFAULT_DRAFT_TITLE = 'New Maker';
const MINUTE_MS = 60 * 1000;
const HOUR_MS = 60 * MINUTE_MS;
const DAY_MS = 24 * HOUR_MS;
const WEEK_MS = 7 * DAY_MS;
const MONTH_MS = 30 * DAY_MS;
const YEAR_MS = 365 * DAY_MS;

export type TaskListCategory = 'projects' | 'dialogues' | 'automations';
export type TaskListSortMode = 'default' | 'recency' | 'alphabetic';
export type TaskRightStatusKind = 'error' | 'waiting' | 'running' | 'done' | 'time';

/**
 * 与 Mobile 会话行同一优先级：运行事实必须压过旧的 completed 未读态，
 * 避免 maker:event 已进入新一轮后，列表仍被迟到的完成活动标成「已完成」。
 */
export function resolveTaskRightStatus(
  livePhase: string,
  liveAttention: boolean,
  pendingInteractionCount: number,
  running: boolean,
): TaskRightStatusKind {
  if (livePhase === 'error' && liveAttention) return 'error';
  if (pendingInteractionCount > 0 || livePhase === 'needs-interaction') return 'waiting';
  if (running || livePhase === 'running') return 'running';
  if (livePhase === 'completed' && liveAttention) return 'done';
  return 'time';
}

/**
 * ArkUI ForEach 会按 key 复用旧任务行；普通 RemoteSession 对象和外部运行态不是
 * @Observed，必须把会改变行内容的字段压成稳定签名，才能让新快照重建对应节点。
 * 不包含当前时间，避免相对时间时钟每分钟触发整表重建。
 */
export function taskListEntryPresentationState(
  session: RemoteSession,
  rightStatus: TaskRightStatusKind,
): string {
  const values = [
    session.title,
    taskPreviewText(session.preview),
    session.agentKind,
    session.status,
    session.pinnedAt,
    taskActivityAt(session),
    rightStatus,
  ];
  let state = '';
  for (let i = 0; i < values.length; i++) {
    state += `${values[i].length}:${values[i]}`;
  }
  return state;
}

/**
 * 沿用 Harmony 原状态筛选口径：优先识别调度器来源，旧数据再用标题前缀识别。
 */
export function taskIsAutomation(session: RemoteSession): boolean {
  return session.source === 'scheduler' || session.title.startsWith('[Schedule]');
}

/** 自动化优先于工作区类型，确保三个首页分类互斥。 */
export function taskListCategory(session: RemoteSession): TaskListCategory {
  if (taskIsAutomation(session)) return 'automations';
  if (session.workspaceKind === 'dialogue' || session.workingDir.length === 0) return 'dialogues';
  return 'projects';
}

/** 去掉状态筛选后的可见性：默认只看活跃任务，搜索时可找回归档任务。 */
export function taskVisibleInTaskList(session: RemoteSession, searchActive: boolean): boolean {
  if (session.status === 'deleted' || session.orcaRole === 'worker') return false;
  return searchActive || session.status === 'active';
}

export function taskDisplayTitle(session: RemoteSession): string {
  const title = session.title.trim();
  if (title.length > 0 && title !== DEFAULT_DRAFT_TITLE) {
    return title;
  }
  return '未命名任务';
}

/**
 * 自动标题的统一归一化，与 `@cindy/maker-shared/session-title` 的 `normalizeAutoTitle`
 * **逐字一致**：折叠空白 → trim → 截断 40 字 → trimEnd。
 *
 * 首条用户消息以此作为占位标题，与被控端自动起名写进 DB 的是同一个串，回流时不跳变。
 * 落库出口、占位覆写方与鸿蒙端的乐观预览都用它算出同一个串。
 */
export function normalizeAutoTitle(text: string): string {
  return text.replace(/\s+/g, ' ').trim().slice(0, 40).trimEnd();
}

/** 附件展示名：只取最后一段，去掉任何路径前缀，不把目录结构泄漏到标题里。 */
export function attachmentDisplayName(name: string): string {
  const parts = name.split(/[\\/]/);
  return parts.length > 0 ? parts[parts.length - 1] : '';
}

/**
 * 新建任务第一帧该显示的乐观标题。
 *
 * 语义对齐 `packages/maker-shared/src/sessionTitle.ts` 的 `deriveOptimisticSessionTitle`：
 * 有用户文字就用原文截断；没有文字时依次用第一个附件的**展示名**（去路径）、
 * 图片类别词、文件类别词。算不出任何素材时返回空串，由调用方落到
 * `taskDisplayTitle` 的「未命名任务」兜底。
 *
 * 远端权威标题一旦到达即覆盖本地预览，之后不得反向覆盖。
 */
export function deriveOptimisticSessionTitle(
  text: string,
  fileNames: string[],
  firstFileIsImage: boolean,
): string {
  const fromText = normalizeAutoTitle(text);
  if (fromText.length > 0) return fromText;
  for (let i = 0; i < fileNames.length; i++) {
    const fromFile = normalizeAutoTitle(attachmentDisplayName(fileNames[i]));
    if (fromFile.length > 0) return fromFile;
  }
  // 附件没有可用文件名时用类别词，仍然比空标题可读。
  if (firstFileIsImage) return OPTIMISTIC_IMAGE_TITLE;
  if (fileNames.length > 0) return OPTIMISTIC_FILE_TITLE;
  return '';
}

/** 纯图片 / 纯文件首条消息在没有可用文件名时的本地化类别标题。 */
const OPTIMISTIC_IMAGE_TITLE = '图片消息';
const OPTIMISTIC_FILE_TITLE = '文件消息';

export function taskPreviewText(preview: string): string {
  return preview.replace(/\s+/g, ' ').trim();
}

function projectPath(workingDir: string): string {
  const trimmed = workingDir.trim();
  const usesBackslash = /^[A-Za-z]:[\\/]/.test(trimmed) || trimmed.startsWith('\\\\');
  const normalized = (usesBackslash ? trimmed.replace(/\\/g, '/') : trimmed).replace(/\/+$/g, '');
  if (normalized.length === 0) return '';

  const segments = normalized.split('/');
  const comparable = usesBackslash ? segments.map((segment: string) => segment.toLowerCase()) : segments;
  for (let i = 0; i < comparable.length; i++) {
    const segment = comparable[i];
    const singleContainer = segment === '.cindy-worktrees'
      || segment === '.xdt-worktrees'
      || segment === '.worktrees';
    const claudeContainer = segment === '.claude'
      && i + 1 < comparable.length
      && comparable[i + 1] === 'worktrees';
    const worktreeNameIndex = i + (claudeContainer ? 2 : 1);
    if ((singleContainer || claudeContainer) && worktreeNameIndex < segments.length) {
      return segments.slice(0, i).join('/');
    }
  }
  return normalized;
}

export function taskProjectName(workingDir: string): string {
  const normalized = projectPath(workingDir);
  if (normalized.length === 0) {
    return '未命名项目';
  }
  const parts = normalized.split('/');
  const last = parts[parts.length - 1];
  return last.length > 0 ? last : normalized;
}

export function taskProjectKey(deviceId: string, workingDir: string): string {
  const normalized = projectPath(workingDir);
  const windowsPath = /^[A-Za-z]:\//.test(normalized) || normalized.startsWith('//');
  return `${deviceId}:${windowsPath ? normalized.toLowerCase() : normalized}`;
}

export function taskActivityAt(session: RemoteSession): string {
  if (session.userSendAt.length > 0) return session.userSendAt;
  if (session.updatedAt.length > 0) return session.updatedAt;
  return session.createdAt;
}

/** 字母排序忽略大小写；原文和 id 只承担稳定兜底，不改变主要语义。 */
export function compareTaskListLabels(left: string, right: string): number {
  const normalizedLeft = left.trim().toLocaleLowerCase();
  const normalizedRight = right.trim().toLocaleLowerCase();
  const normalizedResult = normalizedLeft.localeCompare(normalizedRight);
  if (normalizedResult !== 0) return normalizedResult;
  return left.localeCompare(right);
}

/**
 * 会话排序口径：
 * - 最近优先沿用 Mobile / Desktop 的 userSendAt → updatedAt → createdAt；
 * - 字母排序按用户可见标题；
 * - 默认排序保留被控端提供的稳定顺序，因此比较器返回相等。
 */
export function compareTaskSessionsForList(
  left: RemoteSession,
  right: RemoteSession,
  mode: TaskListSortMode,
): number {
  if (mode === 'default') return 0;
  if (mode === 'recency') {
    const leftActivity = taskActivityAt(left);
    const rightActivity = taskActivityAt(right);
    if (leftActivity !== rightActivity) return leftActivity > rightActivity ? -1 : 1;
  } else {
    const titleResult = compareTaskListLabels(taskDisplayTitle(left), taskDisplayTitle(right));
    if (titleResult !== 0) return titleResult;
  }
  return left.id.localeCompare(right.id);
}

/** 与 Mobile 共享口径：刚刚、分钟、小时、天、周、月、年。 */
export function taskRelativeTime(iso: string, now: number = Date.now()): string {
  if (iso.length === 0) return '';
  const timestamp = Date.parse(iso);
  if (Number.isNaN(timestamp)) return '';
  const elapsed = Math.max(0, now - timestamp);
  if (elapsed < MINUTE_MS) return '刚刚';
  if (elapsed < HOUR_MS) return `${Math.floor(elapsed / MINUTE_MS)} 分钟`;
  if (elapsed < DAY_MS) return `${Math.floor(elapsed / HOUR_MS)} 小时`;
  if (elapsed < WEEK_MS) return `${Math.floor(elapsed / DAY_MS)} 天`;
  if (elapsed < MONTH_MS) return `${Math.floor(elapsed / WEEK_MS)} 周`;
  if (elapsed < YEAR_MS) return `${Math.floor(elapsed / MONTH_MS)} 月`;
  return `${Math.floor(elapsed / YEAR_MS)} 年`;
}

export function taskVisibleOnHome(session: RemoteSession): boolean {
  return session.status === 'active' && session.orcaRole !== 'worker';
}
