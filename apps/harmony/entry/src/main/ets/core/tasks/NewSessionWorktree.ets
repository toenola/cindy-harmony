import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { readObj, readStr, recordOrEmpty } from './TaskModels';

export type NewSessionWorktreeChannel = 'worktree:detect-cwd' | 'worktree:list-branches' | 'worktree:create'
  | 'worktree:discard-precreated' | 'worktree:cancel-precreated' | 'maker:get-new-maker-defaults'
  | 'maker:apply-new-maker-worktree-pref' | 'maker:get-new-maker-worktree-branch-pref'
  | 'maker:apply-new-maker-worktree-branch-pref';

export const NEW_SESSION_WORKTREE_CHANNELS: NewSessionWorktreeChannel[] = [
  'worktree:detect-cwd', 'worktree:list-branches', 'worktree:create', 'worktree:discard-precreated',
  'worktree:cancel-precreated', 'maker:get-new-maker-defaults', 'maker:apply-new-maker-worktree-pref',
  'maker:get-new-maker-worktree-branch-pref', 'maker:apply-new-maker-worktree-branch-pref',
];

export type NewSessionWorktreeInvoke =
  (channel: NewSessionWorktreeChannel, args: Object[]) => Promise<Object | undefined>;

export class NewSessionWorktreeTarget {
  baseRepo: string = '';
  sourceBranch: string = 'HEAD';
  supported: boolean = false;
}

export function parseWorktreeTarget(raw: Object | undefined): NewSessionWorktreeTarget {
  const target = new NewSessionWorktreeTarget();
  const row = recordOrEmpty(raw);
  if (row['isGitRepo'] !== true || row['isInsideWorktree'] !== false || row['gitInstalled'] !== true) return target;
  target.baseRepo = readStr(row, 'repoRoot').trim();
  target.sourceBranch = readStr(row, 'currentBranch').trim() || 'HEAD';
  target.supported = target.baseRepo.length > 0 && row['supportsRecoveryKeyDiscard'] === true;
  return target;
}

export interface WorktreeReservation {
  sessionId: string;
  recoveryKey: string;
  baseRepo: string;
  sourceBranch: string;
  name: string;
}

export function worktreeReservation(sessionId: string, baseRepo: string, sourceBranch: string): WorktreeReservation {
  return { sessionId, baseRepo, sourceBranch, recoveryKey: util.generateRandomUUID(),
    name: 'auto-' + Date.now().toString(36).slice(-6) };
}

export function worktreeCreateOptions(options: Record<string, Object>, path: string): Record<string, Object> {
  if (options['workspaceKind'] !== 'project' || !path) return options;
  const next: Record<string, Object> = {};
  for (const key of Object.keys(options)) next[key] = options[key];
  next['projectDir'] = options['workingDir'];
  next['workingDir'] = path;
  return next;
}

export class WorktreeRecoveryLedger {
  constructor(privateContext: common.Context, storageKey: string) {
    this.context = privateContext;
    this.key = storageKey;
  }

  private context: common.Context;
  private key: string;

  private async prefs(): Promise<preferences.Preferences> {
    return preferences.getPreferences(this.context, { name: 'cindy_new_task_worktree_recovery' });
  }

  async read(): Promise<WorktreeReservation | null> {
    const pref = await this.prefs();
    const raw = await pref.get(this.key, '');
    if (typeof raw !== 'string') throw new Error('Worktree 恢复记录不可读');
    return raw ? JSON.parse(raw) as WorktreeReservation : null;
  }

  async write(record: WorktreeReservation): Promise<void> {
    const pref = await this.prefs();
    await pref.put(this.key, JSON.stringify(record));
    await pref.flush();
  }

  async clear(record: WorktreeReservation): Promise<void> {
    const latest = await this.read();
    if (latest?.sessionId !== record.sessionId || latest.recoveryKey !== record.recoveryKey) return;
    const pref = await this.prefs();
    await pref.delete(this.key);
    await pref.flush();
  }
}

export async function cancelWorktreeReservation(invoke: NewSessionWorktreeInvoke,
  record: WorktreeReservation, allowDiscard: boolean): Promise<void> {
  const locator: Record<string, Object> = {};
  locator['sessionId'] = record.sessionId;
  locator['recoveryKey'] = record.recoveryKey;
  let raw: Object | undefined;
  try {
    raw = await invoke('worktree:cancel-precreated', [locator]);
  } catch (error) {
    if (!allowDiscard || !String(error).includes('CHANNEL_NOT_ALLOWED')) throw new Error('Worktree 清理尚未确认');
    raw = await invoke('worktree:discard-precreated', [locator]);
  }
  if (recordOrEmpty(raw)['discarded'] !== true) throw new Error('Worktree 清理尚未确认');
}

export async function requestWorktreePath(invoke: NewSessionWorktreeInvoke, record: WorktreeReservation): Promise<string> {
  const row = recordOrEmpty(await invoke('worktree:create', [record]));
  const meta = readObj(row, 'meta');
  const path = readStr(meta, 'path').trim();
  if (row['ok'] !== true || !/^(?:\/|[A-Za-z]:[\\/]|\\\\)/.test(path) || readStr(meta, 'sessionId') !== record.sessionId
    || readStr(meta, 'baseRepo') !== record.baseRepo || readStr(meta, 'sourceBranch') !== record.sourceBranch
    || readStr(meta, 'recoveryKey') !== record.recoveryKey) {
    throw new Error('电脑未确认本次 worktree 创建');
  }
  return path;
}

const busyLedgers: Set<string> = new Set();

export class WorktreePreparation {
  private active: boolean = false;
  private attempted: boolean = false;
  private finalized: boolean = false;
  private ledger: WorktreeRecoveryLedger;
  private invoke: NewSessionWorktreeInvoke;
  private record: WorktreeReservation;
  private key: string;

  constructor(context: common.Context, key: string, invoke: NewSessionWorktreeInvoke, record: WorktreeReservation) {
    this.key = key;
    this.ledger = new WorktreeRecoveryLedger(context, key);
    this.invoke = invoke;
    this.record = record;
  }

  async prepare(current: () => boolean): Promise<string> {
    if (this.finalized || this.active || busyLedgers.has(this.key)) throw new Error('请返回编辑后重新创建 worktree');
    this.active = true;
    busyLedgers.add(this.key);
    const previous = await this.ledger.read();
    if (previous !== null) {
      await cancelWorktreeReservation(this.invoke, previous, false);
      await this.ledger.clear(previous);
    }
    await this.ledger.write(this.record);
    this.attempted = true;
    return requestWorktreePath(async (channel, args): Promise<Object | undefined> => {
      if (!current()) throw new Error('新任务创建已取消');
      return this.invoke(channel, args);
    }, this.record);
  }

  async finish(claimed: boolean): Promise<void> {
    if (!this.active) return;
    try {
      if (!this.attempted) return;
      if (!claimed) await cancelWorktreeReservation(this.invoke, this.record, false);
      await this.ledger.clear(this.record);
    } finally {
      this.active = false;
      this.finalized = true;
      busyLedgers.delete(this.key);
    }
  }
}
