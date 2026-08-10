/** 任务列表的隐藏 last-view override；默认值不落盘。 */
import { common } from '@kit.AbilityKit';
import { SecureStore } from '../storage/SecureStore';

const KEY = 'task.list.view.v1';
const MAX_KEYS = 200;

export class TaskListPreferences {
  selectedDeviceId: string = '';
  selectedDeviceName: string = '';
  activeListTab: string = 'projects';
  sortMode: string = 'recency';
  searchQuery: string = '';
  openProjectKeys: string[] = [];
  fullyExpandedProjectKeys: string[] = [];
  pinnedCollapsed: boolean = true;
}

function safeString(record: Record<string, Object>, key: string, max: number): string {
  const value = record[key];
  return typeof value === 'string' ? value.slice(0, max) : '';
}

function safeKeys(value: Object | undefined): string[] {
  if (!Array.isArray(value)) return [];
  const seen = new Set<string>();
  const out: string[] = [];
  const list = value as Object[];
  for (let i = 0; i < list.length && out.length < MAX_KEYS; i++) {
    if (typeof list[i] !== 'string') continue;
    const key = (list[i] as string).slice(0, 512);
    if (key.length === 0 || seen.has(key)) continue;
    seen.add(key);
    out.push(key);
  }
  return out;
}

export function parseTaskListPreferences(raw: string): TaskListPreferences {
  const out = new TaskListPreferences();
  if (raw.length === 0) return out;
  try {
    const parsed = JSON.parse(raw) as Object;
    if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) return out;
    const record = parsed as Record<string, Object>;
    out.selectedDeviceId = safeString(record, 'selectedDeviceId', 512);
    out.selectedDeviceName = safeString(record, 'selectedDeviceName', 256);
    const tab = safeString(record, 'activeListTab', 20);
    if (tab === 'projects' || tab === 'dialogues' || tab === 'automations') out.activeListTab = tab;
    const sortMode = safeString(record, 'sortMode', 20);
    if (sortMode === 'default' || sortMode === 'recency' || sortMode === 'alphabetic') {
      out.sortMode = sortMode;
    }
    // 旧版把自动化放在状态筛选中；升级后迁移到新的一级分类。
    if (safeString(record, 'statusFilter', 20) === 'automation') out.activeListTab = 'automations';
    out.searchQuery = safeString(record, 'searchQuery', 256);
    out.openProjectKeys = safeKeys(record['openProjectKeys']);
    out.fullyExpandedProjectKeys = safeKeys(record['fullyExpandedProjectKeys']);
    if (typeof record['pinnedCollapsed'] === 'boolean') out.pinnedCollapsed = record['pinnedCollapsed'] as boolean;
  } catch (e) {
    return new TaskListPreferences();
  }
  return out;
}

export function serializeTaskListPreferences(value: TaskListPreferences): string {
  const out: Record<string, Object> = {};
  if (value.selectedDeviceId.length > 0) out['selectedDeviceId'] = value.selectedDeviceId;
  if (value.selectedDeviceName.length > 0) out['selectedDeviceName'] = value.selectedDeviceName;
  if (value.activeListTab !== 'projects') out['activeListTab'] = value.activeListTab;
  if (value.sortMode !== 'recency') out['sortMode'] = value.sortMode;
  if (value.searchQuery.length > 0) out['searchQuery'] = value.searchQuery;
  if (value.openProjectKeys.length > 0) out['openProjectKeys'] = value.openProjectKeys;
  if (value.fullyExpandedProjectKeys.length > 0) out['fullyExpandedProjectKeys'] = value.fullyExpandedProjectKeys;
  if (!value.pinnedCollapsed) out['pinnedCollapsed'] = false;
  return JSON.stringify(out);
}

export class TaskListPreferenceStore {
  private store: SecureStore = new SecureStore();
  private current: TaskListPreferences = new TaskListPreferences();
  private timer: number = -1;

  async init(context: common.Context): Promise<void> {
    await this.store.init(context);
    this.current = parseTaskListPreferences(await this.store.get(KEY, ''));
  }

  read(): TaskListPreferences {
    return this.current;
  }

  save(value: TaskListPreferences): void {
    this.current = value;
    if (this.timer >= 0) clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.timer = -1;
      const serialized = serializeTaskListPreferences(this.current);
      if (serialized === '{}') void this.store.remove(KEY);
      else void this.store.set(KEY, serialized);
    }, 350);
  }

  async flush(): Promise<void> {
    if (this.timer >= 0) {
      clearTimeout(this.timer);
      this.timer = -1;
    }
    const serialized = serializeTaskListPreferences(this.current);
    if (serialized === '{}') await this.store.remove(KEY);
    else await this.store.set(KEY, serialized);
  }
}
