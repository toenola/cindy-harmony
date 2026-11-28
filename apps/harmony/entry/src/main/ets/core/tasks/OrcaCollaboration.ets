import { DlClient, DlInvokeOptions } from '../device-link/DlClient';
import { readObj, readStr, recordOrEmpty } from './TaskModels';
import { unwrapInvokeResult } from './TaskStore';

export class OrcaWorker {
  id: string = '';
  deviceId: string = '';
  sessionId: string = '';
  name: string = '';
  /** 显示名：label 存在且不同于 role 时用 label，否则用 role（不带「role #」前缀）。 */
  displayName: string = '';
  /** Worker 会话的 Agent：codex / claude-code / pi / acp（插件引擎）。 */
  agentKind: string = '';
  /** 插件引擎 Worker 的引擎（acp-plugin:<插件>:<引擎>）。 */
  providerId: string = '';
  model: string = '';
  status: string = '';
  reachable: boolean = true;
}

export function parseOrcaWorkers(value: Object | undefined, leadDevice: string): OrcaWorker[] {
  if (!Array.isArray(value)) throw new Error('Invalid Worker list');
  const rows = value as Object[];
  const workers: OrcaWorker[] = [];
  const seen = new Set<string>();
  for (const item of rows) {
    const row = recordOrEmpty(item);
    const id = readStr(row, 'id');
    const sessionId = readStr(row, 'sessionId');
    if (!id || !sessionId || seen.has(id)) continue;
    const session = readObj(row, 'session');
    const execution = readObj(row, 'executionDevice');
    const remoteDevice = readStr(execution, 'deviceId');
    const remoteSession = readStr(execution, 'remoteSessionId');
    if (row['executionDevice'] && (!remoteDevice || !remoteSession)) continue;
    const worker = new OrcaWorker();
    worker.id = id;
    worker.deviceId = remoteDevice || leadDevice;
    worker.sessionId = remoteSession || sessionId;
    worker.reachable = execution['reachable'] !== false;
    const label = readStr(row, 'label');
    const role = readStr(row, 'role') || 'developer';
    worker.name = label && label !== role ? role + ' #' + label : role;
    worker.displayName = label && label !== role ? label : role;
    worker.agentKind = readStr(session, 'agentKind');
    worker.providerId = readStr(session, 'providerId');
    worker.model = [readStr(session, 'agentKind'), readStr(session, 'model'), readStr(execution, 'deviceName')]
      .filter((part: string) => part.length > 0).join(' · ');
    worker.status = readStr(row, 'status');
    workers.push(worker);
    seen.add(id);
  }
  return workers;
}

export class OrcaCollaboration {
  private readonly listeners: Set<(device: string, lead: string) => void> = new Set();
  private readonly reads: Map<string, Promise<OrcaWorker[]>> = new Map();
  private readonly selections: Map<string, OrcaWorker> = new Map();

  private readonly client: DlClient;
  private readonly openLink: (device: string) => Promise<void>;
  private generation: number = 0;

  constructor(client: DlClient, openLink: (device: string) => Promise<void>) {
    this.client = client;
    this.openLink = openLink;
  }

  onChanged(listener: (device: string, lead: string) => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  changed(device: string, value: Object | undefined): void {
    const lead = readStr(recordOrEmpty(value), 'leadSessionId');
    if (lead) this.listeners.forEach((listener: (device: string, lead: string) => void) => listener(device, lead));
  }

  clear(): void {
    this.generation += 1;
    this.reads.clear();
    this.selections.clear();
  }

  selection(device: string, lead: string): OrcaWorker | undefined {
    return this.selections.get(JSON.stringify([device, lead]));
  }

  select(device: string, lead: string, worker: OrcaWorker | undefined): void {
    const key = JSON.stringify([device, lead]);
    this.selections.delete(key);
    if (worker) this.selections.set(key, worker);
    if (this.selections.size > 16) {
      const oldest = this.selections.keys().next();
      if (!oldest.done) this.selections.delete(oldest.value);
    }
  }

  list(device: string, lead: string, epoch: number): Promise<OrcaWorker[]> {
    const key = JSON.stringify([epoch, device, lead]);
    const current = this.reads.get(key);
    if (current) return current;
    const read = this.readWorkers(device, lead);
    this.reads.set(key, read);
    return read.finally(() => {
      if (this.reads.get(key) === read) this.reads.delete(key);
    });
  }

  private async readWorkers(device: string, lead: string): Promise<OrcaWorker[]> {
    return parseOrcaWorkers(await this.invoke(device, 'local-db:orca-workflows:list-workers-by-lead', [lead]), device);
  }

  private async invoke(device: string, channel: string, args: Object[], timeout: number = 15000): Promise<Object | undefined> {
    const generation = this.generation;
    await this.openLink(device);
    if (generation !== this.generation) throw new Error('账号已切换');
    const opts = new DlInvokeOptions();
    opts.channel = channel;
    opts.args = args;
    opts.timeoutMs = timeout;
    opts.preSend = (): void => { if (generation !== this.generation) throw new Error('账号已切换'); };
    return unwrapInvokeResult(await this.client.invoke(device, opts));
  }
}
