import { hilog } from '@kit.PerformanceAnalysisKit';
import { ResourceInvoke, resourceError } from '../resources/ResourceModels';
import { recordOrEmpty, readStr, readNum } from '../tasks/TaskModels';

const TAG = 'CindyProjectSettings';
const READ_DEADLINE_MS = 20000;

export const PROJECT_INFO_GET = 'sidebar-settings:get-project-aliases';
export const PROJECT_INFO_SET = 'sidebar-settings:set-project-info';
export const PROJECT_INFO_CHANGED = 'local-db:project-aliases:changed';
export interface ProjectDirectory { path: string; access: string; }
export interface ProjectProfile { name?: string; icon?: string | null; directories?: ProjectDirectory[]; }
export interface ProjectOwnerStamp { dataOwnerId: string | null; ownerGeneration: number; }
export interface ProjectSnapshot { aliases: Record<string, string>; icons: Record<string, string>;
  directories: Record<string, ProjectDirectory[]>; settingsVersion: number; creationRoot: string;
  platform: string; ownerStamp: ProjectOwnerStamp | null; }
export interface ProjectAutomaticIcon { image: string; source: string; kind: string; candidate: boolean; }
export interface ProjectInfoRequest { create: boolean; projectKey: string; field: string; value: ProjectProfile;
  dataOwnerId: string | null; ownerGeneration: number; repositoryUrl?: string; }
export interface ProjectIconRequest { projectKey: string; }
export interface ProjectLocation { deviceId: string; remoteHostId: string; directory: string; }
export function projectLocation(deviceId: string, key: string): ProjectLocation | null {
  if (key.startsWith('local:')) return { deviceId, remoteHostId: '', directory: key.slice(6) };
  if (!key.startsWith('remote:')) return null;
  const end = key.indexOf(':', 7);
  if (end < 8) return null;
  try { return { deviceId, remoteHostId: decodeURIComponent(key.slice(7, end)), directory: key.slice(end + 1) }; }
  catch { return null; }
}
export function projectIdentity(deviceId: string, projectKey: string): string { return JSON.stringify([deviceId, projectKey]); }
export function parseProjectSnapshot(value: Object | undefined): ProjectSnapshot {
  const row = recordOrEmpty(value), owner = recordOrEmpty(row['ownerStamp']);
  if (!Array.isArray(row['aliases']) || typeof row['platform'] !== 'string') throw new Error('Invalid project snapshot');
  const ownerId = owner['dataOwnerId'], generation = readNum(owner, 'ownerGeneration', -1);
  let stamp: ProjectOwnerStamp | null = null;
  if ((ownerId === null || typeof ownerId === 'string') && Number.isInteger(generation) && generation >= 0) {
    stamp = { dataOwnerId: ownerId as string | null, ownerGeneration: generation };
  }
  if (row['ownerStamp'] !== undefined && stamp === null) throw new Error('Invalid owner stamp');
  const aliases: Record<string, string> = {}, icons: Record<string, string> = {}, directories: Record<string, ProjectDirectory[]> = {};
  for (const entry of (row['aliases'] as Object[]).slice(0, 10000)) {
    const item = recordOrEmpty(entry), key = readStr(item, 'projectKey'), alias = readStr(item, 'alias').trim();
    if (projectLocation('', key) && alias && alias.length <= 80 && aliases[key] === undefined) aliases[key] = alias;
  }
  const iconValues = recordOrEmpty(row['icons']);
  for (const key of Object.keys(iconValues)) { if (projectLocation('', key) && typeof iconValues[key] === 'string') icons[key] = iconValues[key] as string; }
  const directoryValues = recordOrEmpty(row['directories']);
  for (const key of Object.keys(directoryValues)) {
    const entries = directoryValues[key];
    if (!projectLocation('', key)) continue;
    if (!Array.isArray(entries) || entries.length > 10) throw new Error('Invalid project directories');
    const values: ProjectDirectory[] = [];
    for (const entry of (entries as Object[]).slice(0, 10)) {
      const directory = recordOrEmpty(entry), access = readStr(directory, 'access'), path = readStr(directory, 'path');
      if (!path || path.length > 4096 || path.includes('\0') || (access !== 'read' && access !== 'write')
        || values.some((item: ProjectDirectory): boolean => item.path === path)) throw new Error('Invalid project directory');
      values.push({ path, access });
    }
    directories[key] = values;
  }
  return { aliases, icons, directories, platform: readStr(row, 'platform'), ownerStamp: stamp,
    settingsVersion: row['settingsSupported'] === true ? readNum(row, 'settingsVersion', 1) : 0,
    creationRoot: readStr(row, 'creationRoot') };
}
export function validProjectImage(image: string): boolean {
  return image.length <= 300000 && /^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$/.test(image);
}
export class ProjectStore {
  snapshot: ProjectSnapshot | null = null;
  busy: boolean = false;
  saving: boolean = false;
  // Unknown write result is locked until the user checks the computer. No automatic replay.
  uncertain: boolean = false;
  issue: string = '';
  createdProjectKey: string = '';
  pendingProjectKey: string = '';
  pendingRepository: string = '';
  private generation: number = 0;
  private scope: string = '';
  private deviceId: string = '';
  private online: boolean = false;
  private visible: boolean = false;
  private readOperation: Promise<void> | null = null;
  private pending: boolean = false;
  private readGeneration: number = -1;
  private readRevision: number = 0;
  private listeners: Array<() => void> = [];
  private timer: number = -1;
  private iconRequests: Map<string, Promise<Object | undefined>> = new Map();
  private invoke: ResourceInvoke;
  constructor(invoke: ResourceInvoke) { this.invoke = invoke; }
  identity(): string { return JSON.stringify([this.scope, this.deviceId]); }
  onChanged(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => { this.listeners = this.listeners.filter((entry: () => void): boolean => entry !== listener); };
  }
  private emit(): void { this.listeners.forEach((listener: () => void): void => listener()); }
  configure(scope: string, deviceId: string, online: boolean): void {
    const changed = scope !== this.scope || deviceId !== this.deviceId;
    const restored = online && !this.online;
    if (changed) { this.generation++; this.iconRequests.clear(); this.snapshot = null; this.scope = scope; this.deviceId = deviceId;
      this.uncertain = false; this.saving = false; this.issue = ''; this.createdProjectKey = ''; this.pendingProjectKey = ''; this.pendingRepository = ''; }
    this.online = online;
    if (!online) { this.generation++; this.snapshot = null; if (this.saving) this.uncertain = true; this.saving = false; this.issue = 'offline'; }
    if ((changed || restored) && online && this.visible) void this.refresh();
    this.emit();
  }
  setVisible(value: boolean): void { this.visible = value; if (value) void this.refresh(); }
  private current(generation: number): boolean { return generation === this.generation && this.online && !!this.scope && !!this.deviceId; }
  // Bound only these single-peer reads, including link establishment. Never
  // reset the link or replay a request. A late result cannot reach the store.
  private async invokeRead(channel: string, args: Object[]): Promise<Object | undefined> {
    const started = Date.now();
    let timer = -1;
    let result = 'ok';
    hilog.info(0x0000, TAG, 'read_start operation=%{public}s', channel);
    try {
      const deadline = new Promise<Object | undefined>((_resolve, reject): void => {
        timer = setTimeout((): void => reject(new Error('PROJECT_READ_TIMEOUT')), READ_DEADLINE_MS);
      });
      return await Promise.race([this.invoke(this.deviceId, channel, args, READ_DEADLINE_MS), deadline]);
    } catch (error) {
      result = error instanceof Error && error.message === 'PROJECT_READ_TIMEOUT' ? 'timeout' : resourceError(error as Object);
      throw (error instanceof Error ? error : new Error(result));
    } finally {
      clearTimeout(timer);
      hilog.info(0x0000, TAG, 'read_end operation=%{public}s result=%{public}s elapsed_ms=%{public}d',
        channel, result, Date.now() - started);
    }
  }

  refresh(): Promise<void> {
    if (!this.online || !this.scope || !this.visible || !this.deviceId) return Promise.resolve();
    if (this.readOperation) { if (this.generation !== this.readGeneration) this.pending = true; return this.readOperation; }
    hilog.info(0x0000, TAG, 'load_start');
    this.busy = true; const generation = this.generation; this.readGeneration = generation;
    const revision = this.readRevision;
    const operation = this.read(generation, revision).finally((): void => {
      if (this.readOperation !== operation) return;
      this.readOperation = null; this.busy = false;
      hilog.info(0x0000, TAG, 'load_end');
      this.emit();
      if (this.pending) { this.pending = false; void this.refresh(); }
    });
    this.readOperation = operation; this.emit(); return operation;
  }
  private async read(generation: number, revision: number): Promise<void> {
    try {
      const value = await this.invokeRead(PROJECT_INFO_GET, []);
      if (!this.current(generation) || revision !== this.readRevision) {
        hilog.info(0x0000, TAG, 'snapshot_result stale');
        return;
      }
      this.snapshot = parseProjectSnapshot(value);
      hilog.info(0x0000, TAG, 'snapshot_result version=%{public}d owner_stamp=%{public}d',
        this.snapshot.settingsVersion, this.snapshot.ownerStamp === null ? 0 : 1);
      this.issue = this.uncertain ? 'unknown' : '';
    } catch (error) {
      if (this.current(generation)) {
        this.snapshot = null;
        this.issue = resourceError(error as Object);
        hilog.info(0x0000, TAG, 'snapshot_result issue=%{public}s', this.issue);
      }
    }
  }
  async save(projectKey: string, profile: ProjectProfile, create: boolean = false, repositoryUrl: string = ''): Promise<boolean> {
    const snapshot = this.snapshot, location = projectLocation(this.deviceId, projectKey);
    if (!snapshot || !snapshot.ownerStamp || !location || this.saving || this.uncertain || !this.current(this.generation)) return false;
    const version = snapshot.settingsVersion;
    if (version < (create ? 6 : 2) || (profile.directories !== undefined && version < 6)
      || (create && (!location.directory || repositoryUrl) && version < 7)) {
      this.issue = 'unsupported'; this.emit(); return false;
    }
    if ((create && location.remoteHostId) || (profile.name !== undefined && profile.name.trim().length > 80)
      || (profile.directories !== undefined && profile.directories.length > 10)) {
      this.issue = 'invalid'; this.emit(); return false;
    }
    // The host performs repository normalization, Git auth, path and permission validation.
    // The controller never derives local filesystem permissions from these presentation fields.
    if (profile.icon && ((profile.icon.startsWith('symbol:') && profile.icon.split(':').length > 2 && version < 3)
      || (profile.icon.startsWith('text:') && profile.icon.split(':').length > 2 && version < 5))) {
      this.issue = 'unsupported'; this.emit(); return false;
    }
    const generation = this.generation;
    const owner = snapshot.ownerStamp;
    const request: ProjectInfoRequest = { create, projectKey, field: 'profile', value: profile,
      dataOwnerId: owner.dataOwnerId, ownerGeneration: owner.ownerGeneration };
    if (repositoryUrl.trim()) request.repositoryUrl = repositoryUrl.trim();
    this.saving = true; this.issue = ''; this.pendingProjectKey = projectKey; this.pendingRepository = repositoryUrl;
    this.emit();
    let accepted = false;
    try {
      const result = recordOrEmpty(await this.invoke(this.deviceId, PROJECT_INFO_SET, [request], repositoryUrl ? 360000 : undefined));
      if (!this.current(generation)) return false;
      // v7 automatic directory creation must supply its actual allocated identity.
      const returned = readStr(result, 'createdProjectKey');
      if (create && (!returned.startsWith('local:') || !returned.slice(6))) {
        if (version >= 7 || !location.directory) throw new Error('Missing created project identity');
      }
      this.createdProjectKey = create ? returned || projectKey : '';
      accepted = true;
      await this.refresh();
      return this.current(generation);
    } catch (error) {
      if (this.current(generation)) {
        const code = readStr(recordOrEmpty(error as Object), 'code');
        this.issue = resourceError(error as Object);
        // Only explicit host validation/authorization rejection proves a write did not run.
        this.uncertain = !/^(INVALID_ARGUMENT|FORBIDDEN|PERMISSION_DENIED|CHANNEL_NOT_ALLOWED|DEVICE_LINK_CHANNEL_NOT_ALLOWED)$/.test(code);
        if (this.uncertain) this.issue = 'unknown';
      }
      return false;
    } finally {
      if (this.current(generation)) { this.saving = false; if (accepted) { this.pendingProjectKey = ''; this.pendingRepository = ''; } this.emit(); }
    }
  }
  acknowledgeCheckedResult(): void { if (this.saving) return; this.uncertain = false; this.issue = ''; this.emit(); }
  handlePush(deviceId: string, channel: string): void {
    if (deviceId !== this.deviceId || channel !== PROJECT_INFO_CHANGED) return;
    // Invalidate the in-flight snapshot without changing the ownership generation of a write.
    this.readRevision++; if (this.readOperation) this.pending = true;
    if (!this.visible || this.timer >= 0) return;
    this.timer = setTimeout((): void => { this.timer = -1; void this.refresh(); }, 300);
  }
  private iconRequest(projectKey: string, automatic: boolean): Promise<Object | undefined> {
    const key = JSON.stringify([this.identity(), projectKey, automatic]);
    const pending = this.iconRequests.get(key);
    if (pending) return pending;
    const request: ProjectIconRequest = { projectKey };
    const operation = this.invokeRead(automatic ? 'sidebar-settings:get-project-auto-icon' : 'sidebar-settings:get-project-icon-image', [request]);
    this.iconRequests.set(key, operation);
    operation.finally((): void => { if (this.iconRequests.get(key) === operation) this.iconRequests.delete(key); }).catch((): void => {});
    return operation;
  }
  async automaticIcon(projectKey: string): Promise<ProjectAutomaticIcon | null> {
    if (!this.snapshot || this.snapshot.settingsVersion < 4 || !this.current(this.generation)) return null;
    const generation = this.generation;
    const row = recordOrEmpty(await this.iconRequest(projectKey, true));
    if (!this.current(generation)) return null;
    const image = readStr(row, 'image'), source = readStr(row, 'source'), kind = readStr(row, 'kind');
    if (source.length > 2048 || !['local', 'website', 'github', 'none'].includes(kind) || typeof row['candidate'] !== 'boolean'
      || (row['image'] !== null && !validProjectImage(image))) return null;
    return { image, source, kind, candidate: row['candidate'] === true };
  }
  async iconImage(projectKey: string, automatic: boolean = false): Promise<string> {
    if (automatic) return (await this.automaticIcon(projectKey))?.image ?? '';
    if (!this.snapshot || !this.current(this.generation)) return '';
    const generation = this.generation;
    const image = await this.iconRequest(projectKey, false);
    return this.current(generation) && typeof image === 'string' && validProjectImage(image) ? image : '';
  }
  revoke(): void { this.generation++; this.iconRequests.clear(); this.online = false; this.snapshot = null; this.saving = false; this.issue = 'unavailable'; this.emit(); }
  dispose(): void { this.revoke(); this.visible = false; if (this.timer >= 0) clearTimeout(this.timer); this.timer = -1; this.listeners = []; }
}
