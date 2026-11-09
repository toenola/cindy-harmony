/**
 * 远程 Agent：同账号其他电脑上的模型目录（v1.3.5 D2）。
 *
 * 行为事实源：`apps/mobile/src/session/remoteAgentCatalogs.ts`、`useRemoteAgentCatalogs.ts`、
 * `sessionAgentSwitch.ts`（resolveAgentLocationPick）、`packages/model-providers/src/remoteModels.ts`。
 *
 * - 手机直接经 device-link 向那台电脑取 `maker:provider:list`，只保留开了「允许被远程调用」的供应商，
 *   并按 `remoteModelIds` 收窄模型；读的是 Cindy 电脑端，不直连模型厂商。
 * - 有缓存先用缓存，再在后台刷新；读不到只影响那一台，绝不挡住被控电脑自己的目录。
 * - 本期只做同账号其他电脑；供应商分享（`share:<id>`）按同一结构后续接入。
 */

import { DlClient, DlInvokeOptions } from '../device-link/DlClient';
import { PresenceSnapshot } from '../device-link/DlProtocol';
import {
  ComposerModelOption, ModelSelectionHint, ProviderListOptions, parseModelVisibilityOverrides, parseProviderModelOptions,
} from '../ComposerCatalog';
import { deviceDisplayName } from './DeviceDisplayName';
import { readBool, recordOrEmpty } from './TaskModels';
import { unwrapInvokeResult } from './TaskStore';

export const PROVIDER_LIST_CHANNEL = 'maker:provider:list';

/** 一台可选电脑的目录状态；payload 只含开了远程调用的供应商。 */
export class RemoteAgentCatalog {
  deviceId: string = '';
  name: string = '';
  /** loading = 还没读到；error = 读不到（离线 / 没开远程控制 / 旧版本）且没有缓存。 */
  status: string = 'loading';
  /** 此刻连不上，只因任务的 Agent 在这台才留在清单里；目录可能来自缓存。 */
  offline: boolean = false;
  /** 与 `maker:provider:list` 同形的 `{ providers, modelVisibilityOverrides }`；没有时为 undefined。 */
  payload: Object | undefined = undefined;
}

export class RemoteAgentDevice {
  deviceId: string = '';
  name: string = '';
  canOpen: boolean = false;
}

/** 被控电脑的目录带「允许被远程调用」标记，说明它认得远程 Agent 的位置参数。 */
export function remoteAgentLocationSupported(value: Object | undefined): boolean {
  const providers = recordOrEmpty(value)['providers'];
  if (!Array.isArray(providers)) return false;
  for (const provider of providers as Object[]) {
    if (typeof recordOrEmpty(provider)['remoteInvocationEnabled'] === 'boolean') return true;
  }
  return false;
}

/**
 * 那台电脑允许远程调用的供应商（没有该标记的旧数据按未开放处理），并按 `remoteModelIds`
 * 只留允许远程使用的模型。返回与 `maker:provider:list` 同形的结果；不是目录时返回 undefined。
 */
export function remoteAgentProviderList(value: Object | undefined): Object | undefined {
  const root = recordOrEmpty(value);
  const rawProviders = root['providers'];
  if (!Array.isArray(rawProviders)) return undefined;
  const providers: Object[] = [];
  for (const raw of rawProviders as Object[]) {
    const provider = recordOrEmpty(raw);
    if (!readBool(provider, 'remoteInvocationEnabled', false)) continue;
    providers.push(remoteInvocationModels(provider));
  }
  const out: Record<string, Object> = {};
  out['providers'] = providers;
  const overrides = root['modelVisibilityOverrides'];
  if (overrides !== undefined && overrides !== null) out['modelVisibilityOverrides'] = overrides;
  return out;
}

function remoteInvocationModels(provider: Record<string, Object>): Record<string, Object> {
  const ids = provider['remoteModelIds'];
  if (ids === undefined) return provider;
  const allowed = new Set<string>();
  if (Array.isArray(ids) && (ids as Object[]).every((id: Object): boolean => typeof id === 'string')) {
    (ids as Object[]).forEach((id: Object): void => { allowed.add(id as string); });
  }
  const next: Record<string, Object> = {};
  Object.keys(provider).forEach((key: string): void => { next[key] = provider[key]; });
  const models = recordOrEmpty(provider['models']);
  const filtered: Record<string, Object> = {};
  Object.keys(models).forEach((agent: string): void => {
    const list = models[agent];
    filtered[agent] = Array.isArray(list)
      ? (list as Object[]).filter((model: Object): boolean => {
        const id = recordOrEmpty(model)['id'];
        return typeof id === 'string' && allowed.has(id as string);
      })
      : list;
  });
  next['models'] = filtered;
  return next;
}

/**
 * 可以让 Agent 运行的其他电脑：排除被控电脑与没开远程控制的电脑；离线电脑读不了目录不列，
 * 但任务当前（或挂着的）Agent 所在电脑始终保留。可用在前、再按名字，顺序稳定。
 */
export function selectRemoteAgentDevices(devices: PresenceSnapshot[], controlledDeviceId: string,
  keepDeviceIds: string[], unnamed: string): RemoteAgentDevice[] {
  const names = new Map<string, string>();
  for (const device of devices) names.set(device.deviceId, device.deviceName);
  const out: RemoteAgentDevice[] = [];
  for (const device of devices) {
    if (device.deviceId.length === 0 || device.deviceId === controlledDeviceId) continue;
    const canOpen = device.online && device.remoteControlEnabled;
    if (!canOpen && keepDeviceIds.indexOf(device.deviceId) < 0) continue;
    const item = new RemoteAgentDevice();
    item.deviceId = device.deviceId;
    item.name = deviceDisplayName(device.deviceId, device.deviceName, unnamed, names);
    item.canOpen = canOpen;
    out.push(item);
  }
  out.sort((a: RemoteAgentDevice, b: RemoteAgentDevice): number => {
    if (a.canOpen !== b.canOpen) return a.canOpen ? -1 : 1;
    const byName = a.name.localeCompare(b.name);
    return byName !== 0 ? byName : a.deviceId.localeCompare(b.deviceId);
  });
  return out;
}

/**
 * 把各台电脑的远程目录解析成模型行，接在被控电脑自己的目录之后。selection 只作用于 Agent 当前
 * 所在的那台（selectionDeviceId），保证当前模型即使被隐藏也留在目录里。离线电脑的缓存行只为
 * 让用户看到 Agent 在哪台，不能选。
 */
export function remoteAgentModelOptions(catalogs: RemoteAgentCatalog[], agent: string,
  selection: ModelSelectionHint | undefined, selectionDeviceId: string | null): ComposerModelOption[] {
  const out: ComposerModelOption[] = [];
  for (const catalog of catalogs) {
    if (catalog.payload === undefined) continue;
    const hint = selectionDeviceId === catalog.deviceId ? selection : undefined;
    const options = parseProviderModelOptions(catalog.payload, agent,
      parseModelVisibilityOverrides(catalog.payload), hint, hint !== undefined);
    for (const option of options) {
      option.agentDeviceId = catalog.deviceId;
      option.agentDeviceName = catalog.name;
      if (catalog.offline && !option.selectedRoute) option.suspended = true;
      out.push(option);
    }
  }
  return out;
}

/** 选中一行模型时 Agent 位置怎么处理。relocates = false 时位置不变（含撤销挂着的换位置）。 */
export class AgentLocationPick {
  relocates: boolean = false;
  /** 带给被控端的新位置；null = 改回被控电脑。 */
  relocateTo: string | null = null;
  needsConfirm: boolean = false;
}

/**
 * 与 Mobile resolveAgentLocationPick 同口径：catalogDeviceId 是这一行来自哪台电脑的目录（null = 被控电脑）。
 * 与任务当前位置不同才换位置；换到下一条消息时所在电脑以外、且不是当前所在电脑时才确认。
 */
export function resolveAgentLocationPick(current: string | null, effective: string | null,
  catalogDeviceId: string | null): AgentLocationPick {
  const pick = new AgentLocationPick();
  pick.relocates = catalogDeviceId !== current;
  pick.relocateTo = catalogDeviceId;
  pick.needsConfirm = catalogDeviceId !== effective && catalogDeviceId !== current;
  return pick;
}

/** `maker:switch-session-agent` 第 7 个参数：Agent 换到哪台电脑运行；null = 改回被控电脑。 */
export class AgentLocationArgument {
  agentDeviceId: string | null = null;
}

/** 按设备缓存并单飞读取其他电脑的远程目录；账号切换时整体清空。 */
export class RemoteAgentCatalogStore {
  private client: DlClient | undefined = undefined;
  private openLink: ((deviceId: string) => Promise<void>) | undefined = undefined;
  private account: () => string = (): string => '';
  private payloads: Map<string, Object> = new Map();
  private failed: Set<string> = new Set();
  private operations: Map<string, Promise<void>> = new Map();
  private listeners: Array<() => void> = [];
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

  /** 按设备清单拼出当前目录状态（只读，不发请求）。 */
  catalogs(devices: RemoteAgentDevice[]): RemoteAgentCatalog[] {
    return devices.map((device: RemoteAgentDevice): RemoteAgentCatalog => {
      const catalog = new RemoteAgentCatalog();
      catalog.deviceId = device.deviceId;
      catalog.name = device.name;
      catalog.offline = !device.canOpen;
      catalog.payload = this.payloads.get(device.deviceId);
      catalog.status = catalog.payload !== undefined ? 'ready'
        : !device.canOpen || this.failed.has(device.deviceId) ? 'error' : 'loading';
      return catalog;
    });
  }

  /** 对可连接的电脑后台刷新目录；有缓存时继续显示缓存。 */
  refresh(devices: RemoteAgentDevice[]): void {
    for (const device of devices) {
      if (!device.canOpen || this.operations.has(device.deviceId)) continue;
      const operation = this.read(device.deviceId, this.generation, this.account());
      this.operations.set(device.deviceId, operation);
      void operation.then((): void => {
        if (this.operations.get(device.deviceId) === operation) this.operations.delete(device.deviceId);
      });
    }
  }

  resetConnection(): void {
    this.generation += 1;
    this.operations.clear();
    this.failed.clear();
  }

  clearAll(): void {
    this.resetConnection();
    this.payloads.clear();
    this.notify();
  }

  private notify(): void {
    for (const listener of this.listeners.slice()) listener();
  }

  private async read(deviceId: string, generation: number, account: string): Promise<void> {
    const client = this.client;
    if (client === undefined) return;
    const current = (): boolean => generation === this.generation && account === this.account();
    try {
      if (this.openLink !== undefined) await this.openLink(deviceId);
      if (!current()) return;
      const options = new DlInvokeOptions();
      options.channel = PROVIDER_LIST_CHANNEL;
      const request = new ProviderListOptions();
      request.capabilities = ['provider-logo-kinds-v2'];
      options.args = [request];
      const payload = remoteAgentProviderList(unwrapInvokeResult(await client.invoke(deviceId, options)));
      if (!current()) return;
      if (payload === undefined) {
        this.failed.add(deviceId);
      } else {
        this.payloads.set(deviceId, payload);
        this.failed.delete(deviceId);
      }
      this.notify();
    } catch (_error) {
      if (!current()) return;
      // 有缓存继续显示缓存；从未读到过才标成读不到。
      this.failed.add(deviceId);
      this.notify();
    }
  }
}
