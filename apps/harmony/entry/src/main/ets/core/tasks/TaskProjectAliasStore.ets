import { ProjectSnapshot, parseProjectSnapshot, validProjectImage } from '../projects/ProjectStore';
import { DlClient, DlInvokeOptions } from '../device-link/DlClient';
import { RemoteSession, readStr, safeErrorMessage, sessionProjectDirectory } from './TaskModels';
import { normalizeTaskProjectPath } from './TaskProjectOrderStore';
import { unwrapInvokeResult } from './TaskStore';

export const PROJECT_ALIASES_LIST = 'local-db:project-aliases:list';
export const PROJECT_ALIASES_CHANGED = 'local-db:project-aliases:changed';

export function remoteProjectAliasKey(deviceId: string, path: string): string {
  return 'device:' + encodeURIComponent(deviceId) + ':' + normalizeTaskProjectPath(path);
}

export function parseHostProjectAliases(deviceId: string, value: Object | undefined): Map<string, string> {
  if (!Array.isArray(value)) throw new Error('Invalid project aliases response');
  const aliases = new Map<string, string>();
  for (const item of value as Object[]) {
    if (item === null || typeof item !== 'object' || Array.isArray(item)) continue;
    const row = item as Record<string, Object>;
    const key = readStr(row, 'projectKey');
    const alias = readStr(row, 'alias').trim();
    if (!key.startsWith('local:') || key.slice(6).trim().length === 0 || alias.length === 0) continue;
    const resolved = remoteProjectAliasKey(deviceId, key.slice(6));
    if (!aliases.has(resolved)) aliases.set(resolved, alias);
  }
  return aliases;
}

export function resolveProjectAliasForSessions(deviceId: string, sessions: RemoteSession[],
  aliases: Map<string, string>): string {
  let identity = '';
  for (const session of sessions) {
    const projectDir = sessionProjectDirectory(session);
    if (session.remoteHostId.length > 0 || projectDir.length === 0) return '';
    const key = remoteProjectAliasKey(deviceId, projectDir);
    if (identity.length > 0 && identity !== key) return '';
    identity = key;
  }
  return identity.length > 0 ? aliases.get(identity) ?? '' : '';
}

export class TaskProjectAliasStore {
  private client: DlClient | undefined = undefined;
  private openLink: ((deviceId: string) => Promise<void>) | undefined = undefined;
  private account: () => string = (): string => '';
  private snapshots: Map<string, Map<string, string>> = new Map();
  private profiles: Map<string, ProjectSnapshot> = new Map();
  private images: Map<string, string> = new Map();

  icon(device: string, key: string): string { return this.profiles.get(device)?.icons[key] ?? ''; }
  image(device: string, key: string): string { return this.images.get(JSON.stringify([device, key])) ?? ''; }
  alias(device: string, key: string): string { return this.profiles.get(device)?.aliases[key] ?? ''; }
  private listeners: Array<() => void> = [];
  private operations: Map<string, Promise<void>> = new Map();
  private revisions: Map<string, number> = new Map();
  private attempts: Map<string, number> = new Map();
  private timers: Map<string, number> = new Map();
  private generation: number = 0;

  attach(client: DlClient, openLink: (deviceId: string) => Promise<void>, account: () => string): void {
    this.client = client;
    this.openLink = openLink;
    this.account = account;
  }

  onChanged(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => {
      const index = this.listeners.indexOf(listener);
      if (index >= 0) this.listeners.splice(index, 1);
    };
  }

  resolve(deviceId: string, sessions: RemoteSession[]): string {
    return resolveProjectAliasForSessions(deviceId, sessions, this.snapshots.get(deviceId) ?? new Map());
  }

  refresh(deviceId: string, resetAttempts: boolean = true): void {
    if (deviceId.length === 0 || this.client?.getStatus() !== 'online') return;
    if (resetAttempts) this.attempts.delete(deviceId);
    const timer = this.timers.get(deviceId);
    if (timer !== undefined) clearTimeout(timer);
    this.timers.delete(deviceId);
    const revision = (this.revisions.get(deviceId) ?? 0) + 1;
    this.revisions.set(deviceId, revision);
    if (this.operations.has(deviceId)) return;
    const generation = this.generation;
    const account = this.account();
    const operation = this.read(deviceId, revision, generation, account);
    this.operations.set(deviceId, operation);
    void operation.then((): void => {
      if (this.operations.get(deviceId) !== operation) return;
      this.operations.delete(deviceId);
      if (generation === this.generation && account === this.account()
        && this.revisions.get(deviceId) !== revision) this.refresh(deviceId, false);
    });
  }

  resetConnection(): void {
    this.generation += 1;
    this.operations.clear();
    this.revisions.clear();
    this.attempts.clear();
    this.timers.forEach((timer: number): void => clearTimeout(timer));
    this.timers.clear();
  }

  clearAll(): void {
    this.resetConnection();
    this.snapshots.clear(); this.profiles.clear(); this.images.clear();
    for (const listener of this.listeners) listener();
  }

  private async readProfile(client: DlClient, deviceId: string, current: () => boolean): Promise<void> {
    try {
      const request = new DlInvokeOptions(); request.channel = 'sidebar-settings:get-project-aliases'; request.args = [];
      const raw = unwrapInvokeResult(await client.invoke(deviceId, request)); if (!current()) return;
      const profile = parseProjectSnapshot(raw), old = this.profiles.get(deviceId);
      if (old) for (const key of Object.keys(old.icons)) this.images.delete(JSON.stringify([deviceId, key]));
      this.profiles.set(deviceId, profile);
      for (const listener of this.listeners) listener();
      const keys = Object.keys(profile.icons).filter((key: string): boolean => profile.icons[key].startsWith('cindy-media:')).slice(0, 64);
      for (let start = 0; start < keys.length && current(); start += 4) {
        await Promise.all(keys.slice(start, start + 4).map(async (key: string): Promise<void> => {
          try {
            const options = new DlInvokeOptions(); options.channel = 'sidebar-settings:get-project-icon-image';
            const input: Record<string, Object> = {}; input['projectKey'] = key; options.args = [input];
            const image = unwrapInvokeResult(await client.invoke(deviceId, options));
            if (current() && typeof image === 'string' && validProjectImage(image)) this.images.set(JSON.stringify([deviceId, key]), image);
          } catch (_error) {}
        }));
      }
      if (current()) for (const listener of this.listeners) listener();
    } catch (_error) { /* Optional metadata is not authority for the original aliases endpoint. */ }
  }

  private async read(deviceId: string, revision: number, generation: number, account: string): Promise<void> {
    const client = this.client;
    if (client === undefined) return;
    const current = (): boolean => generation === this.generation && account === this.account()
      && this.revisions.get(deviceId) === revision && client.getStatus() === 'online';
    try {
      if (this.openLink !== undefined) await this.openLink(deviceId);
      if (!current()) return;
      const options = new DlInvokeOptions();
      options.channel = PROJECT_ALIASES_LIST;
      options.args = [];
      const aliases = parseHostProjectAliases(deviceId, unwrapInvokeResult(await client.invoke(deviceId, options)));
      if (!current()) return;
      this.snapshots.set(deviceId, aliases); this.attempts.delete(deviceId);
      for (const listener of this.listeners) listener();
      // Profile support is independent of the established aliases endpoint. A
      // failed optional icon/profile read must not suppress or erase valid labels.
      await this.readProfile(client, deviceId, current);
    } catch (error) {
      if (!current()) return;
      const message = safeErrorMessage(error);
      if (message.indexOf('CHANNEL_NOT_ALLOWED') >= 0) {
        this.snapshots.set(deviceId, new Map());
        const old = this.profiles.get(deviceId); this.profiles.delete(deviceId);
        if (old) for (const key of Object.keys(old.icons)) this.images.delete(JSON.stringify([deviceId, key]));
        this.attempts.delete(deviceId);
        for (const listener of this.listeners) listener();
        return;
      }
      const attempt = (this.attempts.get(deviceId) ?? 0) + 1;
      this.attempts.set(deviceId, attempt);
      if (attempt < 3) {
        this.timers.set(deviceId, setTimeout((): void => {
          this.timers.delete(deviceId);
          if (current()) this.refresh(deviceId, false);
        }, 2000));
      }
    }
  }
}
