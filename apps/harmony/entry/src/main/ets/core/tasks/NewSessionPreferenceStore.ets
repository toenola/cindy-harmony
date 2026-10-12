/** Explicit workspace choices, isolated by account. Paths are preserved verbatim. */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { readStr, recordOrEmpty } from './TaskModels';

export class NewSessionPreferences {
  workspaceKind: string = '';
  workingDirByDevice: Record<string, string> = {};
}

export function parseNewSessionPreferences(raw: string): NewSessionPreferences {
  const result = new NewSessionPreferences();
  try {
    const record = recordOrEmpty(JSON.parse(raw) as Object);
    const kind = readStr(record, 'workspaceKind');
    if (kind === 'project' || kind === 'dialogue') result.workspaceKind = kind;
    const dirs = recordOrEmpty(record['workingDirByDevice']);
    for (const deviceId of Object.keys(dirs)) {
      const path = dirs[deviceId];
      if (deviceId !== '__proto__' && deviceId !== 'constructor' && deviceId !== 'prototype'
        && deviceId.length > 0 && typeof path === 'string' && path.trim().length > 0) {
        result.workingDirByDevice[deviceId] = path;
      }
    }
  } catch (e) {}
  return result;
}

/** Workspace preferences survive credential cleanup and never store authorization data. */
export class WorkspacePreferenceStorage {
  private pref: preferences.Preferences | undefined = undefined;
  async init(context: common.Context): Promise<void> {
    const options: preferences.Options = { name: 'cindy_new_session_preferences' };
    this.pref = await preferences.getPreferences(context, options);
  }
  async get(key: string, fallback: string): Promise<string> {
    const value = await this.pref?.get(key, fallback);
    return typeof value === 'string' ? value : fallback;
  }
  async set(key: string, value: string): Promise<void> {
    if (this.pref === undefined) throw new Error('Workspace preferences not initialized');
    await this.pref.put(key, value);
    await this.pref.flush();
  }
}

export class NewSessionPreferenceStore {
  private store: WorkspacePreferenceStorage;

  constructor(store: WorkspacePreferenceStorage = new WorkspacePreferenceStorage()) { this.store = store; }
  private owner: string = '';
  private generation: number = 0;
  private current: NewSessionPreferences = new NewSessionPreferences();
  private writes: Promise<void> = Promise.resolve();
  private ready: Promise<void> = Promise.resolve();
  private editRevision: number = 0;

  async init(context: common.Context): Promise<void> { await this.store.init(context); }

  async setAccountScope(owner: string): Promise<void> {
    if (this.owner === owner && this.generation > 0) return this.ready;
    const generation = ++this.generation;
    this.owner = owner;
    this.current = new NewSessionPreferences();
    if (owner.length === 0) return;
    const revision = this.editRevision;
    this.ready = this.restore(owner, generation, revision);
    await this.ready;
  }

  private async restore(owner: string, generation: number, revision: number): Promise<void> {
    await this.writes;
    let raw = '';
    try { raw = await this.store.get(this.key(owner), ''); }
    catch (_e) { hilog.warn(0x0000, 'CindyPreferences', 'workspace preference read failed'); }
    if (generation === this.generation && revision === this.editRevision) {
      this.current = parseNewSessionPreferences(raw);
    }
  }

  read(): NewSessionPreferences { return this.current; }

  save(deviceId: string, kind: string, path: string): void {
    if (this.owner.length === 0 || (kind !== 'dialogue' && kind !== 'project')) return;
    this.editRevision += 1;
    this.current.workspaceKind = kind;
    if (deviceId.length > 0 && kind === 'project' && path.trim().length > 0) {
      this.current.workingDirByDevice[deviceId] = path;
    }
    const key = this.key(this.owner);
    const raw = JSON.stringify(this.current);
    // Capture both owner and contents now; a later account cannot inherit this write.
    this.writes = this.writes.then(() => this.store.set(key, raw)).catch(() => { hilog.warn(0x0000, 'CindyPreferences', 'workspace preference write failed'); });
  }

  private key(owner: string): string { return `new.session.preferences.v1.${encodeURIComponent(owner)}`; }
}
