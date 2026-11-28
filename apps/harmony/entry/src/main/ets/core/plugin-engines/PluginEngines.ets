import { readNum, readObj, readStr, recordOrEmpty } from '../tasks/TaskModels';

const PREFIX = 'acp-plugin:';
export const MAX_PLUGIN_ENGINES = 32;

export class PluginEngineModel {
  id: string = 'default';
  label: string = '默认模型';
  efforts: string[] = [];
}

export class PluginEngine {
  providerId: string = '';
  name: string = '';
  iconDataUrl: string = '';
  availability: string = 'unknown';
  availabilityMessage: string = '';
  models: PluginEngineModel[] = [];
  reportsUsage: boolean = false;
}

export function pluginEngineKey(providerId: string): string {
  if (!providerId.startsWith(PREFIX)) return '';
  const key = providerId.slice(PREFIX.length);
  const separator = key.lastIndexOf(':');
  return separator > 0 && separator < key.length - 1 ? key : '';
}

export function isPluginEngineSession(agentKind: string, providerId: string): boolean {
  if (agentKind === 'codex' || agentKind === 'cc' || agentKind === 'claude-code' || agentKind === 'pi') return false;
  return agentKind === 'acp' || pluginEngineKey(providerId).length > 0;
}

export function findPluginEngine(engines: PluginEngine[], providerId: string): PluginEngine | undefined {
  return engines.find((engine: PluginEngine): boolean => engine.providerId === providerId);
}

export function normalizePluginEngines(value: Object | undefined): PluginEngine[] {
  if (!Array.isArray(value)) return [];
  const engines: PluginEngine[] = [];
  let remainingIconChars = 512 * 1024;
  for (const entry of (value as Object[]).slice(0, MAX_PLUGIN_ENGINES)) {
    const raw = recordOrEmpty(entry);
    const providerId = readStr(raw, 'providerId');
    const name = readStr(raw, 'name').trim().slice(0, 64);
    if (!pluginEngineKey(providerId) || !name || findPluginEngine(engines, providerId) !== undefined) continue;
    const engine = new PluginEngine();
    engine.providerId = providerId;
    engine.name = name;
    const state = readStr(readObj(raw, 'availability'), 'state');
    if (state === 'available' || state === 'unavailable') engine.availability = state;
    engine.availabilityMessage = readStr(readObj(raw, 'availability'), 'message').trim().slice(0, 200);
    const models = raw['models'];
    if (Array.isArray(models)) {
      const ids = new Set<string>();
      for (const entry of (models as Object[]).slice(0, 200)) {
        const row = recordOrEmpty(entry);
        const id = readStr(row, 'id');
        if (!id.trim() || id.length > 256 || ids.has(id)) continue;
        ids.add(id);
        const model = new PluginEngineModel();
        model.id = id;
        model.label = (readStr(row, 'displayName').trim() || readStr(row, 'label').trim() || id).slice(0, 200);
        const efforts = row['efforts'];
        if (Array.isArray(efforts)) {
          model.efforts = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max']
            .filter((level: string): boolean => (efforts as Object[]).includes(level));
        }
        engine.models.push(model);
      }
    }
    engine.reportsUsage = raw['reportsUsage'] === true;
    const icon = readStr(raw, 'iconDataUrl');
    if (icon.startsWith('data:image/') && icon.length <= 64 * 1024 && icon.length <= remainingIconChars) {
      engine.iconDataUrl = icon;
      remainingIconChars -= icon.length;
    }
    engines.push(engine);
  }
  return engines;
}

export class PluginUsageWindow {
  label: string = '';
  remainingPercent: number = 0;
  resetsAt: number = 0;
}

export class PluginUsageBalance {
  currency: string = '';
  amount: string = '';
}

export class PluginUsage {
  updatedAt: number = 0;
  windows: PluginUsageWindow[] = [];
  balances: PluginUsageBalance[] = [];
}

function validTimestamp(value: number): boolean {
  return Number.isSafeInteger(value) && value > 0 && value <= 8.64e15;
}

/** Only show measured quota. Missing/invalid replies never become a fabricated zero. */
export function normalizePluginUsage(value: Object | undefined): PluginUsage | null {
  const raw = recordOrEmpty(value);
  const usage = new PluginUsage();
  usage.updatedAt = readNum(raw, 'updatedAt', 0);
  if (!validTimestamp(usage.updatedAt)) return null;
  const windows = raw['windows'];
  const balances = raw['balances'];
  if (windows !== undefined) {
    if (!Array.isArray(windows) || windows.length > 24) return null;
    for (const item of windows as Object[]) {
      const row = recordOrEmpty(item);
      const window = new PluginUsageWindow();
      window.label = readStr(row, 'label');
      window.remainingPercent = readNum(row, 'remainingPercent', NaN);
      const resetsAt = readNum(row, 'resetsAt', NaN);
      if (!window.label.trim() || window.label.length > 120 || !Number.isFinite(window.remainingPercent)
        || window.remainingPercent < 0 || window.remainingPercent > 100
        || (row['resetsAt'] !== undefined && !validTimestamp(resetsAt))) return null;
      window.resetsAt = Number.isFinite(resetsAt) ? resetsAt : 0;
      usage.windows.push(window);
    }
  }
  if (balances !== undefined) {
    if (!Array.isArray(balances) || balances.length > 8) return null;
    for (const item of balances as Object[]) {
      const row = recordOrEmpty(item);
      const balance = new PluginUsageBalance();
      balance.currency = readStr(row, 'currency');
      balance.amount = readStr(row, 'amount');
      if (!/^[A-Z]{3}$/.test(balance.currency) || !/^-?\d{1,15}(?:\.\d{1,12})?$/.test(balance.amount)) return null;
      usage.balances.push(balance);
    }
  }
  return usage.windows.length || usage.balances.length ? usage : null;
}

export function pluginPickerModels(engine: PluginEngine, activeModel: string): PluginEngineModel[] {
  if (engine.models.length === 0) return [new PluginEngineModel()];
  if (activeModel === 'default' && !engine.models.some((model: PluginEngineModel): boolean => model.id === 'default')) {
    return [new PluginEngineModel()].concat(engine.models);
  }
  return engine.models;
}
