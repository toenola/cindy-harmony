import {
  ComposerModelOption,
  modelNeedsReselection,
  reconcileModelEffort,
  resolveNewSessionDefaultModel,
} from '../ComposerCatalog';
import { readBool, readStr } from './TaskModels';

export class NewSessionRuntime {
  model: string = '';
  providerId: string = '';
  effort: string = '';
  fastMode: boolean = false;
}

export function runtimeDefaultsScope(accountId: string, deviceId: string, agent: string): string {
  return JSON.stringify([accountId, deviceId, agent]);
}

export function hostDraftRuntimeFromDefaults(value: Object | undefined): NewSessionRuntime | null {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) return null;
  const record = value as Record<string, Object>;
  const model = readStr(record, 'model').trim();
  const providerId = readStr(record, 'providerId');
  if (model.length === 0 || (record['modelChosenByUser'] === false && providerId.length === 0)) return null;
  const runtime = new NewSessionRuntime();
  runtime.model = model;
  runtime.providerId = providerId;
  runtime.effort = readStr(record, 'effort').trim();
  runtime.fastMode = readBool(record, 'fastMode', false);
  return runtime;
}

export function isHostDraftDefaultsReady(value: Object | undefined): boolean {
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) return false;
  return Object.keys(value).indexOf('worktreeEnabled') >= 0;
}

export async function readNewSessionRuntimeDefaults(
  read: () => Promise<Object | undefined>,
  isCurrent: () => boolean,
  wait: () => Promise<void>,
): Promise<NewSessionRuntime | null> {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    if (!isCurrent()) return null;
    let value: Object | undefined = undefined;
    try {
      value = await read();
    } catch {
      return null;
    }
    if (!isCurrent()) return null;
    if (value === undefined || isHostDraftDefaultsReady(value) || attempt === 2) {
      return hostDraftRuntimeFromDefaults(value);
    }
    await wait();
  }
  return null;
}

export function pickNewSessionRuntime(
  agent: string,
  preferred: NewSessionRuntime | null,
  models: ComposerModelOption[],
  visibility: Map<string, boolean>,
): NewSessionRuntime {
  const runtime = new NewSessionRuntime();
  const usable = models.filter((option: ComposerModelOption): boolean =>
    option.availability !== 'requires_payment' && !option.suspended
      && !modelNeedsReselection(visibility, agent, option.id, option.providerId));
  let selected: ComposerModelOption | undefined = undefined;
  if (preferred !== null) {
    const hidden = modelNeedsReselection(visibility, agent, preferred.model, preferred.providerId);
    selected = models.find((option: ComposerModelOption): boolean =>
      option.id === preferred.model && (preferred.providerId.length === 0 || option.providerId === preferred.providerId));
    if (hidden) {
      runtime.model = preferred.model;
      runtime.providerId = preferred.providerId;
      runtime.effort = selected === undefined ? preferred.effort : reconcileModelEffort(selected, preferred.effort);
      runtime.fastMode = preferred.fastMode && selected?.supportsFastMode === true;
      return runtime;
    }
    selected = preferred.providerId.length > 0
      ? usable.find((option: ComposerModelOption): boolean =>
        option.id === preferred.model && option.providerId === preferred.providerId)
      : undefined;
    if (selected === undefined) {
      const offerings = usable.filter((option: ComposerModelOption): boolean => option.id === preferred.model);
      selected = defaultSourceOption(agent, offerings);
    }
  }
  if (selected === undefined) {
    selected = preferred === null ? resolveNewSessionDefaultModel(usable, agent) ?? usable[0] : usable[0];
  }
  if (selected === undefined) return runtime;
  runtime.model = selected.id;
  runtime.providerId = selected.providerId;
  runtime.effort = reconcileModelEffort(selected, preferred?.effort ?? '');
  runtime.fastMode = preferred !== null && preferred.fastMode && preferred.model === selected.id
    && (preferred.providerId.length === 0 || preferred.providerId === selected.providerId)
    && selected.supportsFastMode;
  return runtime;
}

function defaultSourceOption(agent: string, offerings: ComposerModelOption[]): ComposerModelOption | undefined {
  const selectedRoute = offerings.find((option: ComposerModelOption): boolean => option.selectedRoute);
  if (selectedRoute !== undefined) return selectedRoute;
  if (agent === 'codex') {
    const openAi = offerings.find((option: ComposerModelOption): boolean => option.providerId === 'openai');
    if (openAi !== undefined) return openAi;
  }
  return offerings.find((option: ComposerModelOption): boolean => option.providerId === 'xd') ?? offerings[0];
}

export function newSessionDraftPref(
  agent: string,
  runtime: NewSessionRuntime,
  active: boolean,
  markModelChoice: boolean,
): Record<string, Object> {
  const pref: Record<string, Object> = {};
  pref['agent'] = agent;
  pref['providerId'] = runtime.providerId;
  pref['modelId'] = runtime.model;
  pref['active'] = active;
  if (active) pref['markModelChoice'] = markModelChoice;
  if (runtime.effort.length > 0) pref['effort'] = runtime.effort;
  pref['fast'] = runtime.fastMode;
  return pref;
}

export function newSessionRuntimeCanCreate(
  settled: boolean,
  catalogReady: boolean,
  agent: string,
  runtime: NewSessionRuntime,
  visibility: Map<string, boolean>,
): boolean {
  return settled && catalogReady && runtime.model.trim().length > 0
    && !modelNeedsReselection(visibility, agent, runtime.model, runtime.providerId);
}

export class NewSessionRuntimeChoices {
  private choices: Map<string, NewSessionRuntime> = new Map();

  read(scope: string): NewSessionRuntime | null {
    return this.choices.get(scope) ?? null;
  }

  remember(scope: string, runtime: NewSessionRuntime): void {
    this.choices.set(scope, runtime);
  }
}

export class NewSessionDraftPrefWriter {
  private pending: Map<string, Promise<void>> = new Map();

  enqueue(scope: string, write: () => Promise<void>): Promise<void> {
    const previous = this.pending.get(scope) ?? Promise.resolve();
    const next = previous.then(write).catch(() => {});
    this.pending.set(scope, next);
    void next.then((): void => {
      if (this.pending.get(scope) === next) this.pending.delete(scope);
    });
    return next;
  }
}

export class NewSessionDirectoryDrive {
  name: string = '';
  path: string = '';
  current: boolean = false;
}

export function normalizeRemoteDirectoryDrives(value: Object | undefined): NewSessionDirectoryDrive[] {
  const drives: NewSessionDirectoryDrive[] = [];
  const seen = new Set<string>();
  if (!Array.isArray(value)) return drives;
  for (const item of value as Object[]) {
    if (item === null || typeof item !== 'object' || Array.isArray(item)) continue;
    const record = item as Record<string, Object>;
    const path = readStr(record, 'path');
    if (path.length === 0 || seen.has(path)) continue;
    seen.add(path);
    const drive = new NewSessionDirectoryDrive();
    drive.path = path;
    drive.name = readStr(record, 'name') || path;
    drive.current = readBool(record, 'current', false);
    drives.push(drive);
  }
  return drives.length > 1 ? drives : [];
}

export function shouldRetryRemoteBrowseDrives(pending: Object | undefined, attempt: number): boolean {
  return pending === true && attempt >= 0 && attempt < 3;
}
