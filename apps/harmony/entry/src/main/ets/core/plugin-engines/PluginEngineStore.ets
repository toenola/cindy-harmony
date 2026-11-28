import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  PluginEngine, PluginUsage, findPluginEngine, normalizePluginEngines, normalizePluginUsage, pluginEngineKey,
} from './PluginEngines';

type PluginRead = (deviceId: string, channel: string, args: Object[], current: () => boolean) => Promise<Object | undefined>;

class CachedPluginUsage {
  result: Promise<PluginUsage | null> = Promise.resolve(null);
  freshUntil: number = Infinity;
}

const CACHE_MS = 60000;

/** Memory only, scoped to the current account and relay route. No background reads or timers. */
export class PluginEngineStore {
  private scope: string = '';
  private engines: Map<string, PluginEngine[]> = new Map<string, PluginEngine[]>();
  private reading: Map<string, Promise<PluginEngine[]>> = new Map<string, Promise<PluginEngine[]>>();
  private usage: Map<string, Map<string, CachedPluginUsage>> = new Map<string, Map<string, CachedPluginUsage>>();

  private readonly owner: () => string;
  private readonly read: PluginRead;

  constructor(owner: () => string, read: PluginRead) {
    this.owner = owner;
    this.read = read;
  }

  private syncScope(): string {
    const scope = this.owner();
    if (scope !== this.scope) {
      this.scope = scope;
      this.engines.clear();
      this.reading.clear();
      this.usage.clear();
    }
    return scope;
  }

  listCached(deviceId: string): PluginEngine[] {
    this.syncScope();
    return this.engines.get(deviceId) ?? [];
  }

  find(deviceId: string, providerId: string): PluginEngine | undefined {
    return findPluginEngine(this.listCached(deviceId), providerId);
  }

  load(deviceId: string, refresh: boolean = false): Promise<PluginEngine[]> {
    const scope = this.syncScope();
    if (!scope || !deviceId) return Promise.resolve([]);
    const previous = this.engines.get(deviceId) ?? [];
    if (!refresh && previous.length > 0) return Promise.resolve(previous);
    const pending = this.reading.get(deviceId);
    if (pending !== undefined) return pending;
    const current = (): boolean => scope === this.owner();
    const request = this.read(deviceId, 'maker:list-plugin-engines', [], current);
    const run: Promise<PluginEngine[]> = request.then((raw: Object | undefined): PluginEngine[] => {
      if (!current()) return [];
      if (!Array.isArray(raw)) {
        hilog.debug(0, 'CindyPluginMark', 'catalog_invalid');
        return previous;
      }
      const next = normalizePluginEngines(raw);
      hilog.debug(0, 'CindyPluginMark', 'catalog_loaded engines=%{public}d icons=%{public}d',
        next.length, next.filter((engine: PluginEngine): boolean => !!engine.iconDataUrl).length);
      this.engines.set(deviceId, next);
      const entries = this.usage.get(deviceId);
      entries?.forEach((_read: CachedPluginUsage, id: string): void => {
        if (findPluginEngine(next, id)?.reportsUsage !== true) entries.delete(id);
      });
      return next;
    }).catch((): PluginEngine[] => {
      if (!current()) return [];
      hilog.debug(0, 'CindyPluginMark', 'catalog_read_failed');
      return previous;
    }).finally((): void => {
      if (this.reading.get(deviceId) === run) this.reading.delete(deviceId);
    });
    this.reading.set(deviceId, run);
    return run;
  }

  readUsage(deviceId: string, providerId: string): Promise<PluginUsage | null> {
    const scope = this.syncScope();
    const key = pluginEngineKey(providerId);
    if (!scope || !deviceId || !key) return Promise.resolve(null);
    const engines = this.engines.get(deviceId);
    if (engines !== undefined && findPluginEngine(engines, providerId)?.reportsUsage !== true) return Promise.resolve(null);
    const entries = this.usage.get(deviceId) ?? new Map<string, CachedPluginUsage>();
    const now = Date.now();
    const previous = entries.get(providerId);
    if (previous !== undefined && now < previous.freshUntil) return previous.result;
    entries.forEach((entry: CachedPluginUsage, id: string): void => {
      if (entry.freshUntil <= now) entries.delete(id);
    });
    const entry = new CachedPluginUsage();
    entries.set(providerId, entry);
    this.usage.set(deviceId, entries);
    const current = (): boolean => scope === this.owner() && entries.get(providerId) === entry;
    entry.result = this.read(deviceId, 'maker:get-plugin-engine-usage', [key], current)
      .then((raw: Object | undefined): PluginUsage | null => current() ? normalizePluginUsage(raw) : null)
      .catch((): null => null).finally((): void => { entry.freshUntil = now + CACHE_MS; });
    return entry.result;
  }
}
