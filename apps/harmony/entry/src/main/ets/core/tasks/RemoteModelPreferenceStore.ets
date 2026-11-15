/** Explicit effort and speed choices for models running on another computer. */
import { common } from '@kit.AbilityKit';
import { WorkspacePreferenceStorage } from './NewSessionPreferenceStore';

export function remoteModelPreferenceKey(agent: string, deviceId: string, providerId: string, modelId: string): string {
  return JSON.stringify([agent, deviceId, providerId, modelId]);
}

export class RemoteModelPreferenceStore {
  private storage: WorkspacePreferenceStorage;
  private owner: string = '';
  private generation: number = 0;
  private values: Record<string, string> = {};
  private writes: Promise<void> = Promise.resolve();
  private ready: Promise<void> = Promise.resolve();
  private revision: number = 0;

  constructor(storage: WorkspacePreferenceStorage = new WorkspacePreferenceStorage()) {
    this.storage = storage;
  }

  async init(context: common.Context): Promise<void> { await this.storage.init(context); }

  async setAccountScope(owner: string): Promise<void> {
    if (owner === this.owner && this.generation > 0) return this.ready;
    const generation = ++this.generation;
    this.owner = owner;
    this.values = {};
    if (!owner) return;
    const revision = this.revision;
    this.ready = this.restore(owner, generation, revision);
    await this.ready;
  }

  private async restore(owner: string, generation: number, revision: number): Promise<void> {
    await this.writes;
    try {
      const raw = await this.storage.get(this.storageKey(owner), '{}');
      const parsed = JSON.parse(raw) as Object;
      if (generation !== this.generation || revision !== this.revision || !parsed || typeof parsed !== 'object'
        || Array.isArray(parsed)) return;
      const clean: Record<string, string> = {};
      const record = parsed as Record<string, Object>;
      for (const key of Object.keys(record)) {
        const value = record[key];
        if (key.length <= 512 && typeof value === 'string' && value.length <= 80) clean[key] = value as string;
      }
      this.values = clean;
    } catch (_error) { /* Bad or missing local preference follows the remote recommendation. */ }
  }

  read(key: string, field: 'effort' | 'speed'): string {
    return this.values[JSON.stringify([key, field])] ?? '';
  }

  save(key: string, field: 'effort' | 'speed', value: string): void {
    if (!this.owner || !key || value.length > 80) return;
    this.revision += 1;
    const slot = JSON.stringify([key, field]);
    if (value) this.values[slot] = value;
    else {
      const remaining: Record<string, string> = {};
      for (const candidate of Object.keys(this.values)) {
        if (candidate !== slot) remaining[candidate] = this.values[candidate];
      }
      this.values = remaining;
    }
    const storageKey = this.storageKey(this.owner);
    const raw = JSON.stringify(this.values);
    this.writes = this.writes.then(() => this.storage.set(storageKey, raw)).catch(() => {});
  }

  private storageKey(owner: string): string { return `remote.model.preferences.v1.${encodeURIComponent(owner)}`; }
}
