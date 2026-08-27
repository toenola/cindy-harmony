/**
 * 任务搜索集成层。
 *
 * 搜索语义与 Mobile / Desktop 的 conversationSearch 对齐：每台设备独立
 * fan-out `local-db:conversations:search`，旧端或离线时只在已缓存的标题与
 * 消息预览上搜索。这里不把搜索结果写回普通任务列表，结果只负责打开任务。
 */

import { DlClient, DlError, DlInvokeOptions } from '../device-link/DlClient';
import { DlChannels } from '../device-link/DlProtocol';
import { RemoteSession, parseSession, readNum, readObj, readStr, safeErrorMessage } from './TaskModels';
import { TaskStore, unwrapInvokeResult } from './TaskStore';

export const TASK_SEARCH_LIMIT = 24;
export const TASK_SEARCH_DEBOUNCE_MS = 250;

export type TaskSearchSortBy = 'relevance' | 'activityDesc' | 'activityAsc';
export type TaskSearchStatusFilter = 'active' | 'archived' | 'all';
export type TaskSearchAgentFilter = 'all' | 'cc' | 'codex' | 'pi';
export type TaskSearchLastActivityFilter = 'all' | '1d' | '3d' | '7d' | '30d';
export type TaskSearchMatchKind = 'title' | 'content' | 'both';
export type TaskSearchStatus = 'idle' | 'searching' | 'ready';

export class TaskSearchFilters {
  status: TaskSearchStatusFilter = 'all';
  agentKind: TaskSearchAgentFilter = 'all';
  lastActivity: TaskSearchLastActivityFilter = 'all';
  workingDirs: string[] | null = null;
}

export class TaskSearchRequest {
  query: string = '';
  limit: number = TASK_SEARCH_LIMIT;
  sortBy: TaskSearchSortBy = 'relevance';
  semanticMode: string = 'keyword';
  unnamedLabel: string = '未命名任务';
  filters: TaskSearchFilters = new TaskSearchFilters();
}

/** 设备范围。offline 设备仍保留在搜索源中，但 reachable=false 时走缓存。 */
export class TaskSearchOrigin {
  deviceId: string = '';
  deviceName: string = '';
  reachable: boolean = false;
  workingDirs: string[] | null = null;
}

export class TaskSearchResult {
  session: RemoteSession = new RemoteSession();
  deviceId: string = '';
  deviceName: string = '';
  matchKind: TaskSearchMatchKind = 'title';
  titleScore: number = 0;
  rankScore: number = 0;
  contentPreview: string = '';
  contentMessageClientId: string = '';
  locallyCached: boolean = false;
}

export class TaskSearchProjectOption {
  key: string = '';
  deviceId: string = '';
  deviceName: string = '';
  title: string = '';
  workingDir: string = '';
  /** 本地项目键会折叠 Windows 大小写；发给远端筛选时保留所有原始路径变体。 */
  remoteWorkingDirs: string[] = [];
  count: number = 0;
}

export class TaskSearchPage {
  query: string = '';
  results: TaskSearchResult[] = [];
  usedCacheFallback: boolean = false;
  searchedDeviceCount: number = 0;
  remoteDeviceCount: number = 0;
  cachedDeviceCount: number = 0;
}

export function emptyTaskSearchPage(query: string = ''): TaskSearchPage {
  const page = new TaskSearchPage();
  page.query = query;
  return page;
}

/**
 * 解析被控端 conversation search 返回的共享响应。
 * 搜索摘要字段比 RemoteSession 少时仍生成一个可打开的任务快照；详情页
 * 随后会用 sessions:get 对账，失败时也能依靠这个摘要启动消息历史加载。
 */
export function parseTaskSearchResponse(
  raw: Object | undefined,
  query: string,
  deviceId: string,
  deviceName: string,
): TaskSearchPage {
  const page = emptyTaskSearchPage(query);
  if (raw === undefined || raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    return page;
  }
  const response = raw as Record<string, Object>;
  const values = response['results'];
  if (!Array.isArray(values)) return page;
  const resultValues = values as Object[];
  for (let i = 0; i < resultValues.length; i++) {
    const value: Object = resultValues[i];
    if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
      continue;
    }
    const item = value as Record<string, Object>;
    const sessionValue = item['session'];
    if (sessionValue === undefined || sessionValue === null
      || typeof sessionValue !== 'object' || Array.isArray(sessionValue)) continue;
    const session = parseSession(sessionValue as Record<string, Object>);
    if (session.id.length === 0) continue;

    const result = new TaskSearchResult();
    result.session = session;
    result.deviceId = deviceId;
    result.deviceName = deviceName;
    result.rankScore = readNum(item, 'rankScore', 0);
    result.titleScore = readNum(item, 'titleScore', 0);
    const rawKind = readStr(item, 'matchKind');
    result.matchKind = rawKind === 'content' || rawKind === 'both' ? rawKind : 'title';

    let hit = readObj(item, 'contentHit');
    if (Object.keys(hit).length === 0) {
      const contentHits = item['contentHits'];
      if (Array.isArray(contentHits) && contentHits.length > 0
        && contentHits[0] !== null && typeof contentHits[0] === 'object') {
        hit = contentHits[0] as Record<string, Object>;
      }
    }
    result.contentPreview = readStr(hit, 'preview');
    if (result.contentPreview.length === 0) result.contentPreview = readStr(hit, 'snippet');
    result.contentMessageClientId = readStr(hit, 'messageClientId');
    page.results.push(result);
  }
  return page;
}

/** 在响应真正带回其它目录的结果时，说明老端忽略了 workingDirs。 */
export function remoteTaskSearchIgnoredWorkingDirs(
  page: TaskSearchPage,
  workingDirs: string[] | null,
): boolean {
  const allowed = normalizeTaskSearchWorkingDirSet(workingDirs);
  if (allowed === null) return false;
  for (let i = 0; i < page.results.length; i++) {
    const current = normalizeTaskSearchWorkingDir(page.results[i].session.workingDir);
    if (current.length === 0 || !allowed.has(current)) return true;
  }
  return false;
}

/** 结果端再做一次过滤，避免旧桌面端忽略 request.filters。 */
export function filterTaskSearchPage(
  page: TaskSearchPage,
  request: TaskSearchRequest,
): TaskSearchPage {
  const filtered = emptyTaskSearchPage(page.query);
  filtered.usedCacheFallback = page.usedCacheFallback;
  filtered.searchedDeviceCount = page.searchedDeviceCount;
  filtered.remoteDeviceCount = page.remoteDeviceCount;
  filtered.cachedDeviceCount = page.cachedDeviceCount;
  for (let i = 0; i < page.results.length; i++) {
    if (taskSearchResultMatchesFilters(page.results[i], request.filters)) {
      filtered.results.push(page.results[i]);
    }
  }
  return filtered;
}

/** 离线 / 老端安全降级：只搜索当前控制端持有的标题与消息预览。 */
export function searchCachedTaskSessions(
  origin: TaskSearchOrigin,
  request: TaskSearchRequest,
  sessions: RemoteSession[],
): TaskSearchPage {
  const page = emptyTaskSearchPage(request.query.trim());
  page.usedCacheFallback = true;
  page.searchedDeviceCount = 1;
  page.cachedDeviceCount = 1;
  const query = request.query.trim().toLowerCase();
  if (query.length === 0) return page;

  for (let i = 0; i < sessions.length; i++) {
    const session = sessions[i];
    if (session.id.length === 0 || session.status === 'deleted' || session.orcaRole === 'worker') continue;
    if (origin.deviceId.length > 0 && !matchesTaskSearchWorkingDir(session.workingDir, origin.workingDirs)) {
      continue;
    }
    const title = taskSearchDisplayTitle(session, request.unnamedLabel).toLowerCase();
    const content = session.preview.toLowerCase();
    const titleHit = title.indexOf(query) >= 0;
    const contentHit = content.indexOf(query) >= 0;
    if (!titleHit && !contentHit) continue;

    const result = new TaskSearchResult();
    result.session = session;
    result.deviceId = origin.deviceId;
    result.deviceName = origin.deviceName;
    result.matchKind = titleHit && contentHit ? 'both' : (titleHit ? 'title' : 'content');
    result.rankScore = 1_000_000 - i;
    result.contentPreview = session.preview;
    result.locallyCached = true;
    if (taskSearchResultMatchesFilters(result, request.filters)) page.results.push(result);
  }
  sortTaskSearchResults(page.results, request.sortBy);
  const limit = Math.max(1, request.limit);
  if (page.results.length > limit) page.results = page.results.slice(0, limit);
  return page;
}

export function mergeTaskSearchPages(
  pages: TaskSearchPage[],
  request: TaskSearchRequest,
): TaskSearchPage {
  const merged = emptyTaskSearchPage(request.query.trim());
  const byKey = new Map<string, TaskSearchResult>();
  for (let i = 0; i < pages.length; i++) {
    const page = pages[i];
    merged.searchedDeviceCount += page.searchedDeviceCount;
    merged.remoteDeviceCount += page.remoteDeviceCount;
    merged.cachedDeviceCount += page.cachedDeviceCount;
    merged.usedCacheFallback = merged.usedCacheFallback || page.usedCacheFallback;
    for (let j = 0; j < page.results.length; j++) {
      const item = page.results[j];
      const key = `${item.deviceId}:${item.session.id}`;
      const existing = byKey.get(key);
      // 同一设备的 indexed 与 fallback 投影同时出现时，始终保留权威正文命中。
      if (existing === undefined || (existing.locallyCached && !item.locallyCached)
        || item.rankScore > existing.rankScore) {
        byKey.set(key, item);
      }
    }
  }
  byKey.forEach((item: TaskSearchResult) => merged.results.push(item));
  sortTaskSearchResults(merged.results, request.sortBy);
  const limit = Math.max(1, request.limit);
  if (merged.results.length > limit) merged.results = merged.results.slice(0, limit);
  return merged;
}

export function taskSearchActiveFilterCount(
  filters: TaskSearchFilters,
  projectKeys: string[],
): number {
  let count = 0;
  if (filters.status !== 'all') count += 1;
  if (filters.agentKind !== 'all') count += 1;
  if (filters.lastActivity !== 'all') count += 1;
  if (projectKeys.length > 0) count += 1;
  return count;
}

export function taskSearchDisplayTitle(session: RemoteSession, unnamedLabel: string): string {
  const title = session.title.trim();
  if (title.length > 0 && title !== 'New Maker') return title;
  return unnamedLabel.length > 0 ? unnamedLabel : '未命名任务';
}

/** 项目筛选选项与普通列表共用 deviceId:归一化目录主键，避免跨设备串项目。 */
export function listTaskSearchProjects(
  deviceId: string,
  deviceName: string,
  sessions: RemoteSession[],
): TaskSearchProjectOption[] {
  const byKey = new Map<string, TaskSearchProjectOption>();
  for (let i = 0; i < sessions.length; i++) {
    const session = sessions[i];
    if (session.status === 'deleted' || session.orcaRole === 'worker'
      || session.workspaceKind === 'dialogue') continue;
    const workingDir = normalizeTaskSearchWorkingDir(session.workingDir);
    if (workingDir.length === 0) continue;
    const key = `${deviceId}:${workingDir}`;
    const existing = byKey.get(key);
    if (existing !== undefined) {
      existing.count += 1;
      const remoteWorkingDir = session.workingDir.trim();
      if (remoteWorkingDir.length > 0 && existing.remoteWorkingDirs.indexOf(remoteWorkingDir) < 0) {
        existing.remoteWorkingDirs.push(remoteWorkingDir);
      }
      continue;
    }
    const option = new TaskSearchProjectOption();
    option.key = key;
    option.deviceId = deviceId;
    option.deviceName = deviceName;
    option.workingDir = workingDir;
    option.title = taskSearchProjectTitle(workingDir);
    option.remoteWorkingDirs = [session.workingDir.trim()];
    option.count = 1;
    byKey.set(key, option);
  }
  const out: TaskSearchProjectOption[] = [];
  byKey.forEach((option: TaskSearchProjectOption) => out.push(option));
  out.sort((left: TaskSearchProjectOption, right: TaskSearchProjectOption) => {
    return left.title.localeCompare(right.title)
      || left.deviceName.localeCompare(right.deviceName)
      || left.key.localeCompare(right.key);
  });
  return out;
}

export function normalizeTaskSearchWorkingDir(raw: string): string {
  const trimmed = raw.trim();
  if (trimmed.length === 0) return '';
  const withoutLongPrefix = stripWindowsLongPathPrefix(trimmed);
  const windows = isWindowsPathLike(trimmed) || isWindowsPathLike(withoutLongPrefix);
  let out = windows ? withoutLongPrefix.replace(/\\/g, '/') : withoutLongPrefix;
  while (out.length > 1 && out.endsWith('/') && !/^[A-Za-z]:\/$/.test(out)) {
    out = out.slice(0, -1);
  }
  const parts = out.split('/');
  const comparableParts = windows
    ? parts.map((part: string) => part.toLowerCase()) : parts;
  for (let i = 0; i < parts.length; i++) {
    const single = comparableParts[i] === '.cindy-worktrees' || comparableParts[i] === '.xdt-worktrees'
      || comparableParts[i] === '.worktrees';
    const claude = comparableParts[i] === '.claude' && i + 2 < parts.length
      && comparableParts[i + 1] === 'worktrees';
    const markerEnd = claude ? i + 2 : i + 1;
    if ((single || claude) && markerEnd < parts.length) {
      const base = parts.slice(0, i).join('/');
      if (base.length === 0) return '/';
      return windows ? base.toLowerCase() : base;
    }
  }
  return windows ? out.toLowerCase() : out;
}

/**
 * 应用级搜索 Store。网络请求放在这里，页面只负责筛选状态、代次和结果呈现。
 */
export class TaskSearchStore {
  private client: DlClient | undefined = undefined;
  private tasks: TaskStore | undefined = undefined;
  private linkOpener: ((deviceId: string) => Promise<void>) | undefined = undefined;

  attach(
    client: DlClient,
    tasks: TaskStore,
    linkOpener: (deviceId: string) => Promise<void>,
  ): void {
    this.client = client;
    this.tasks = tasks;
    this.linkOpener = linkOpener;
  }

  async search(origins: TaskSearchOrigin[], request: TaskSearchRequest): Promise<TaskSearchPage> {
    const query = request.query.trim();
    if (query.length === 0 || origins.length === 0) return emptyTaskSearchPage(query);
    const normalized = copyTaskSearchRequest(request);
    normalized.query = query;
    const pages: Array<Promise<TaskSearchPage>> = [];
    for (let i = 0; i < origins.length; i++) {
      pages.push(this.searchOneDevice(origins[i], normalized));
    }
    const resolved = await Promise.all(pages);
    return mergeTaskSearchPages(resolved, normalized);
  }

  private async searchOneDevice(
    origin: TaskSearchOrigin,
    request: TaskSearchRequest,
  ): Promise<TaskSearchPage> {
    const sessions = this.tasks?.getSessions(origin.deviceId) ?? [];
    if (!origin.reachable || this.client === undefined) {
      return searchCachedTaskSessions(origin, request, sessions);
    }
    try {
      if (this.linkOpener !== undefined) await this.linkOpener(origin.deviceId);
      const opts = new DlInvokeOptions();
      opts.channel = DlChannels.CONVERSATIONS_SEARCH;
      opts.args = [requestForTaskSearchOrigin(origin, request)];
      const env = await this.client.invoke(origin.deviceId, opts);
      const indexed = parseTaskSearchResponse(
        unwrapInvokeResult(env), request.query, origin.deviceId, origin.deviceName,
      );
      if (remoteTaskSearchIgnoredWorkingDirs(indexed, origin.workingDirs)) {
        return await this.searchLegacySessions(origin, request, sessions);
      }
      indexed.searchedDeviceCount = 1;
      indexed.remoteDeviceCount = 1;
      return filterTaskSearchPage(indexed, request);
    } catch (error) {
      if (isTaskSearchChannelNotAllowed(error)) {
        return await this.searchLegacySessions(origin, request, sessions);
      }
      return searchCachedTaskSessions(origin, request, sessions);
    }
  }

  private async searchLegacySessions(
    origin: TaskSearchOrigin,
    request: TaskSearchRequest,
    cachedSessions: RemoteSession[],
  ): Promise<TaskSearchPage> {
    if (this.client !== undefined) {
      try {
        const opts = new DlInvokeOptions();
        opts.channel = DlChannels.SESSIONS_LIST;
        opts.args = [100, legacyStatusForTaskSearch(request)];
        const env = await this.client.invoke(origin.deviceId, opts);
        const result = unwrapInvokeResult(env);
        const sessions = parseTaskSearchSessionList(result);
        return searchCachedTaskSessions(origin, request, sessions);
      } catch (_error) {
        // 老桌面连 sessions:list 也不支持时，继续使用控制端已有快照。
      }
    }
    return searchCachedTaskSessions(origin, request, cachedSessions);
  }
}

function requestForTaskSearchOrigin(
  origin: TaskSearchOrigin,
  request: TaskSearchRequest,
): TaskSearchRequest {
  const next = copyTaskSearchRequest(request);
  if (origin.workingDirs !== null && origin.workingDirs.length > 0) {
    next.filters.workingDirs = origin.workingDirs.slice();
  }
  return next;
}

function copyTaskSearchRequest(request: TaskSearchRequest): TaskSearchRequest {
  const next = new TaskSearchRequest();
  next.query = request.query;
  next.limit = request.limit;
  next.sortBy = request.sortBy;
  next.semanticMode = 'keyword';
  next.unnamedLabel = request.unnamedLabel;
  const filters = new TaskSearchFilters();
  filters.status = request.filters.status;
  filters.agentKind = request.filters.agentKind;
  filters.lastActivity = request.filters.lastActivity;
  filters.workingDirs = request.filters.workingDirs === null
    ? null : request.filters.workingDirs.slice();
  next.filters = filters;
  return next;
}

function parseTaskSearchSessionList(result: Object | undefined): RemoteSession[] {
  const out: RemoteSession[] = [];
  if (result === undefined || result === null || !Array.isArray(result)) return out;
  const values = result as Object[];
  for (let i = 0; i < values.length; i++) {
    const value = values[i];
    if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
      const session = parseSession(value as Record<string, Object>);
      if (session.id.length > 0) out.push(session);
    }
  }
  return out;
}

function legacyStatusForTaskSearch(request: TaskSearchRequest): string {
  return request.filters.status === 'active' || request.filters.status === 'archived'
    ? request.filters.status : 'all';
}

function isTaskSearchChannelNotAllowed(error: Object | undefined): boolean {
  if (error instanceof DlError) {
    return error.code === 'CHANNEL_NOT_ALLOWED'
      || error.code === 'DEVICE_LINK_CHANNEL_NOT_ALLOWED';
  }
  if (error !== null && typeof error === 'object' && !Array.isArray(error)) {
    const code = readStr(error as Record<string, Object>, 'code');
    if (code === 'CHANNEL_NOT_ALLOWED' || code === 'DEVICE_LINK_CHANNEL_NOT_ALLOWED') return true;
  }
  const text = safeErrorMessage(error);
  return text.indexOf('CHANNEL_NOT_ALLOWED') >= 0;
}

function taskSearchResultMatchesFilters(
  result: TaskSearchResult,
  filters: TaskSearchFilters,
): boolean {
  if (!matchesTaskSearchWorkingDir(result.session.workingDir, filters.workingDirs)) return false;
  if (result.session.status === 'deleted') return false;
  if (filters.status === 'active' && result.session.status !== 'active') return false;
  if (filters.status === 'archived' && result.session.status !== 'archived') return false;
  if (filters.status === 'all'
    && result.session.status !== 'active' && result.session.status !== 'archived') return false;
  if (filters.agentKind !== 'all' && result.session.agentKind !== filters.agentKind) return false;
  const cutoff = taskSearchActivityCutoff(filters.lastActivity);
  if (cutoff >= 0 && taskSearchActivityMs(result.session) < cutoff) return false;
  return true;
}

function matchesTaskSearchWorkingDir(workingDir: string, allowed: string[] | null): boolean {
  if (allowed === null || allowed.length === 0) return true;
  const current = normalizeTaskSearchWorkingDir(workingDir);
  if (current.length === 0) return false;
  const normalizedAllowed = normalizeTaskSearchWorkingDirSet(allowed);
  return normalizedAllowed !== null && normalizedAllowed.has(current);
}

function normalizeTaskSearchWorkingDirSet(value: string[] | null): Set<string> | null {
  if (value === null || value.length === 0) return null;
  const out = new Set<string>();
  for (let i = 0; i < value.length; i++) {
    const normalized = normalizeTaskSearchWorkingDir(value[i]);
    if (normalized.length > 0) out.add(normalized);
  }
  return out.size > 0 ? out : null;
}

function taskSearchActivityCutoff(filter: TaskSearchLastActivityFilter): number {
  let days = 0;
  if (filter === '1d') days = 1;
  else if (filter === '3d') days = 3;
  else if (filter === '7d') days = 7;
  else if (filter === '30d') days = 30;
  if (days === 0) return -1;
  return Date.now() - days * 24 * 60 * 60 * 1000;
}

function taskSearchActivityMs(session: RemoteSession): number {
  return Math.max(parseTaskSearchTime(session.userSendAt), parseTaskSearchTime(session.updatedAt));
}

function parseTaskSearchTime(value: string): number {
  if (value.length === 0) return 0;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function sortTaskSearchResults(results: TaskSearchResult[], sortBy: TaskSearchSortBy): void {
  results.sort((left: TaskSearchResult, right: TaskSearchResult) => {
    if (sortBy === 'activityDesc') {
      return taskSearchActivityMs(right.session) - taskSearchActivityMs(left.session)
        || taskSearchRelevanceCompare(left, right);
    }
    if (sortBy === 'activityAsc') {
      return taskSearchActivityMs(left.session) - taskSearchActivityMs(right.session)
        || taskSearchRelevanceCompare(left, right);
    }
    return taskSearchRelevanceCompare(left, right);
  });
}

function taskSearchRelevanceCompare(left: TaskSearchResult, right: TaskSearchResult): number {
  const leftTitle = left.matchKind === 'title' || left.matchKind === 'both' ? 1 : 0;
  const rightTitle = right.matchKind === 'title' || right.matchKind === 'both' ? 1 : 0;
  return rightTitle - leftTitle
    || right.rankScore - left.rankScore
    || taskSearchActivityMs(right.session) - taskSearchActivityMs(left.session)
    || left.deviceId.localeCompare(right.deviceId)
    || left.session.id.localeCompare(right.session.id);
}

function taskSearchProjectTitle(workingDir: string): string {
  const parts = workingDir.split('/');
  for (let i = parts.length - 1; i >= 0; i--) {
    if (parts[i].length > 0) return parts[i];
  }
  return workingDir;
}

function stripWindowsLongPathPrefix(value: string): string {
  if (value.startsWith('\\\\?\\UNC\\')) return `\\\\${value.slice('\\\\?\\UNC\\'.length)}`;
  if (value.startsWith('\\\\?\\')) return value.slice('\\\\?\\'.length);
  return value;
}

function isWindowsPathLike(value: string): boolean {
  return /^[A-Za-z]:[\\/]/.test(value) || value.startsWith('\\\\') || value.startsWith('//');
}
