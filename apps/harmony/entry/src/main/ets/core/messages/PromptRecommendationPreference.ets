/** Phone-local preference, matching Mobile: default on; a failed read must not bypass a saved opt-out. */
import { common } from '@kit.AbilityKit';
import { SecureStore } from '../storage/SecureStore';
const KEY = 'harmony.prompt-recommendation.v1';
export interface PromptPreferenceStorage {
  get(key: string, fallback: string): Promise<string>;
  set(key: string, value: string): Promise<void>;
  remove(key: string): Promise<void>;
}
class SecurePromptPreferenceStorage implements PromptPreferenceStorage {
  private store: SecureStore;
  constructor(store: SecureStore) { this.store = store; }
  get(key: string, fallback: string): Promise<string> { return this.store.get(key, fallback); }
  set(key: string, value: string): Promise<void> { return this.store.set(key, value); }
  remove(key: string): Promise<void> { return this.store.remove(key); }
}
export class PromptRecommendationPreference {
  ready: boolean = false;
  enabled: boolean = false;
  customized: boolean = false;
  private store: PromptPreferenceStorage | null = null;
  private loading: Promise<void> | null = null;
  private revision: number = 0;
  private writes: Promise<void> = Promise.resolve();
  private listeners: Array<() => void> = [];
  onChanged(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => { this.listeners = this.listeners.filter((item: () => void): boolean => item !== listener); };
  }
  private notify(): void { this.listeners.forEach((listener: () => void): void => listener()); }
  async init(context: common.Context): Promise<void> {
    const store = new SecureStore();
    try { await store.init(context); await this.load(new SecurePromptPreferenceStorage(store)); }
    catch (_error) { this.ready = true; this.enabled = false; this.notify(); }
  }
  load(store: PromptPreferenceStorage): Promise<void> {
    if (this.loading !== null) return this.loading;
    this.store = store;
    const revision = this.revision;
    const pending = store.get(KEY, '').then((raw: string): void => {
      if (revision !== this.revision) return;
      this.ready = true; this.enabled = raw !== 'false'; this.customized = raw === 'true' || raw === 'false';
      this.notify();
    }).catch((): void => {
      if (revision !== this.revision) return;
      this.ready = true; this.enabled = false; this.customized = false; this.loading = null; this.notify();
    });
    this.loading = pending;
    return pending;
  }
  save(enabled: boolean | null): Promise<void> {
    const revision = ++this.revision;
    this.ready = true; this.enabled = enabled ?? true;
    this.customized = enabled !== null || this.customized;
    this.notify();
    const write = this.writes.catch((): void => {}).then(async (): Promise<void> => {
      if (this.store === null) throw new Error('Preference storage unavailable');
      if (enabled === null) {
        await this.store.remove(KEY);
        if (this.revision === revision) { this.customized = false; this.notify(); }
      } else await this.store.set(KEY, String(enabled));
    });
    this.writes = write;
    return write;
  }
}
