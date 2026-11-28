import { DlClient, DlInvokeOptions } from '../device-link/DlClient';
import { RemoteSession, readNum, readObj, readStr, recordOrEmpty } from './TaskModels';
import { unwrapInvokeResult } from './TaskStore';
import {
  COMPANION_CREATE_REF_ID, CompanionCreateForm, companionCreatedId, normalizeTeammateName, parseCompanionCreateForm,
} from './CompanionCreate';

export class TeammateRosterEntry {
  id: string = '';
  deviceId: string = '';
  session: RemoteSession = new RemoteSession();
  name: string = '';
  avatarKind: string = '';
  avatarValue: string = '';
  avatarFallback: string = '';
  preview: string = '';
  running: boolean = false;
  timestamp: number = 0;
  replyAt: number = 0;
  readAt: number = -1;
}

function teammateConversationId(row: Record<string, Object>): string {
  const links = row['links'];
  if (!Array.isArray(links)) return '';
  for (const item of links as Object[]) {
    const link = recordOrEmpty(item);
    const target = readObj(link, 'target');
    if (readStr(link, 'rel') === 'conversation' && readStr(target, 'kind') === 'session') {
      return readStr(target, 'sessionId');
    }
  }
  return '';
}

export class TeammateSettingForm {
  actionId: string = '';
  values: Record<string, Object> = {};
  summary: string = '';
}

export function parseTeammateRoster(value: Object | undefined, device: string): TeammateRosterEntry[] {
  const raw = recordOrEmpty(value)['items'];
  if (!Array.isArray(raw)) throw new Error('Invalid teammate roster');
  const result: TeammateRosterEntry[] = [];
  for (const item of raw as Object[]) {
    const row = recordOrEmpty(item);
    const ref = readObj(row, 'ref');
    const id = readStr(ref, 'id');
    if (readStr(ref, 'collectionId') !== 'teammates' || readStr(ref, 'kind') !== 'bot' || !id) continue;
    const sessionId = teammateConversationId(row);
    if (!sessionId) continue;
    const display = readObj(row, 'display');
    const entry = new TeammateRosterEntry();
    entry.id = id;
    entry.deviceId = device;
    entry.session.id = sessionId;
    entry.session.source = 'bot';
    entry.name = readStr(display, 'title') || id;
    entry.session.title = entry.name;
    const avatar = readObj(display, 'avatar');
    entry.avatarKind = readStr(avatar, 'kind');
    entry.avatarValue = readStr(avatar, 'value');
    entry.avatarFallback = readStr(avatar, 'fallbackText') || Array.from(entry.name)[0] || '';
    entry.preview = readStr(display, 'preview') || readStr(display, 'subtitle');
    const phase = readStr(readObj(display, 'teammateActivity'), 'phase');
    entry.running = phase !== 'needs-interaction' && phase !== 'error'
      && (phase === 'running' || Object.keys(readObj(display, 'generation')).length > 0);
    entry.timestamp = readNum(display, 'timestamp', 0);
    entry.replyAt = readNum(display, 'lastReplyAt', 0);
    entry.readAt = readNum(display, 'lastReadAt', -1);
    result.push(entry);
  }
  return result;
}

export class TeammateRoster {
  private client: DlClient;
  private openLink: (device: string) => Promise<void>;
  private revision: number = 0;
  private pending: Map<string, Promise<TeammateRosterEntry[]>> = new Map();
  private listeners: Set<(device: string) => void> = new Set();
  private snapshotListeners: Set<(device: string) => void> = new Set();
  private entriesByDevice: Map<string, TeammateRosterEntry[]> = new Map();
  private visibleTargets: Map<string, TeammateRosterEntry> = new Map();
  private localReadAt: Map<string, number> = new Map();

  constructor(client: DlClient, openLink: (device: string) => Promise<void>) {
    this.client = client;
    this.openLink = openLink;
  }

  clear(): void {
    this.revision += 1;
    this.pending.clear();
    this.entriesByDevice.clear();
    this.visibleTargets.clear();
    this.localReadAt.clear();
  }

  onChanged(listener: (device: string) => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  onSnapshotChanged(listener: (device: string) => void): () => void {
    this.snapshotListeners.add(listener);
    return () => { this.snapshotListeners.delete(listener); };
  }

  changed(device: string, value: Object | undefined): void {
    if (readStr(recordOrEmpty(value), 'collectionId') !== 'teammates') return;
    this.listeners.forEach((listener: (device: string) => void) => listener(device));
  }

  list(device: string): Promise<TeammateRosterEntry[]> {
    const pending = this.pending.get(device);
    if (pending) return pending;
    const request = this.read(device);
    this.pending.set(device, request);
    return request.finally(() => {
      if (this.pending.get(device) === request) this.pending.delete(device);
    });
  }

  private async read(device: string): Promise<TeammateRosterEntry[]> {
    const revision = this.revision;
    const request = this.request();
    request['limit'] = 200;
    const rows = parseTeammateRoster(await this.invoke(device, 'maker:remote-resources:list', request), device);
    if (revision !== this.revision) return [];
    for (const row of rows) {
      const local = this.localReadAt.get(JSON.stringify([device, row.id]));
      if (local !== undefined) row.readAt = Math.max(row.readAt, local);
    }
    this.entriesByDevice.set(device, rows);
    this.snapshotListeners.forEach((listener: (device: string) => void) => listener(device));
    return rows;
  }

  findConversation(device: string, session: string): TeammateRosterEntry | undefined {
    return this.entriesByDevice.get(device)?.find((row: TeammateRosterEntry) => row.session.id === session);
  }

  async settings(row: TeammateRosterEntry): Promise<Map<string, TeammateSettingForm>> {
    const request = this.request(true, false);
    request['ref'] = this.resourceRef(row.id);
    const raw = recordOrEmpty(await this.invoke(row.deviceId, 'maker:remote-resources:get', request));
    const ref = readObj(raw, 'ref');
    if (readStr(ref, 'id') !== row.id || readStr(ref, 'collectionId') !== 'teammates'
      || readStr(ref, 'kind') !== 'bot' || teammateConversationId(raw) !== row.session.id) {
      throw new Error('伙伴主对话已变更');
    }
    const forms = new Map<string, TeammateSettingForm>();
    const blocks = raw['blocks'];
    const actions = raw['actions'];
    if (!Array.isArray(blocks) || !Array.isArray(actions)) return forms;
    for (const item of blocks as Object[]) {
      const block = recordOrEmpty(item);
      const id = readStr(block, 'id');
      if (!['profile', 'memory', 'models'].includes(id) || readStr(block, 'primitive') !== 'form') continue;
      const data = readObj(block, 'data');
      const actionId = readStr(data, 'actionId');
      if (id === 'models' && data['acceptsModelSelection'] !== true) continue;
      if (!actionId || !(actions as Object[]).some((value: Object) => {
        const action = recordOrEmpty(value);
        return readStr(action, 'id') === actionId && action['disabled'] !== true;
      })) continue;
      const form = new TeammateSettingForm();
      form.actionId = actionId;
      const values = readObj(data, 'values');
      if (id === 'profile' && typeof values['name'] !== 'string') continue;
      if (id === 'memory' && typeof values['memory'] !== 'boolean') continue;
      if (id === 'models' && typeof values['followsDefault'] !== 'boolean') continue;
      form.values = values;
      form.summary = readStr(block, 'fallbackMarkdown');
      forms.set(id, form);
    }
    return forms;
  }

  async saveSettings(row: TeammateRosterEntry, actionId: string, input: Record<string, Object>,
    preSend: () => void): Promise<void> {
    const request = this.request(true);
    request['resourceRef'] = this.resourceRef(row.id);
    request['actionId'] = actionId;
    request['input'] = input;
    const receipt = recordOrEmpty(await this.invoke(row.deviceId, 'maker:remote-resources:invoke', request, preSend));
    if (!Array.isArray(receipt['effects'])) throw new Error('电脑未确认保存');
    this.changed(row.deviceId, request);
  }

  /** 已读到的该电脑伙伴名（规范化后），用于提交前的重名提示；电脑端仍会拒绝列表外的重名。 */
  takenNames(device: string): string[] {
    return (this.entriesByDevice.get(device) ?? []).map((row: TeammateRosterEntry) => normalizeTeammateName(row.name));
  }

  /** 读取电脑端的新建伙伴表单（Mobile loadCompanionProfile(ref=teammates/bot/create)）。 */
  async createForm(device: string, locale: string): Promise<CompanionCreateForm> {
    const request = this.request(true, false);
    (request['client'] as Record<string, Object>)['locale'] = locale;
    request['ref'] = this.resourceRef(COMPANION_CREATE_REF_ID);
    return parseCompanionCreateForm(await this.invoke(device, 'maker:remote-resources:get', request), locale);
  }

  /**
   * 提交新建伙伴；返回电脑端确认的伙伴 id。requestId 由调用方保管：结果未确认时重试必须复用，
   * 电脑端按「同一控制端 + requestId」找回同一个伙伴。成功后按 changed 推送同样的路径刷新列表。
   */
  async create(device: string, locale: string, actionId: string, name: string, avatar: string,
    requestId: string): Promise<string> {
    const request = this.request(true);
    (request['client'] as Record<string, Object>)['locale'] = locale;
    const input: Record<string, Object> = {};
    input['name'] = name;
    input['avatarImageBase64'] = avatar;
    input['requestId'] = requestId;
    request['resourceRef'] = this.resourceRef(COMPANION_CREATE_REF_ID);
    request['actionId'] = actionId;
    request['input'] = input;
    const id = companionCreatedId(await this.invoke(device, 'maker:remote-resources:invoke', request));
    if (!id) throw new Error('Creation receipt missing');
    const change: Record<string, Object> = {};
    change['collectionId'] = 'teammates';
    this.changed(device, change);
    return id;
  }

  expectVisible(row: TeammateRosterEntry): void {
    this.visibleTargets.clear();
    this.visibleTargets.set(JSON.stringify([row.deviceId, row.session.id]), row);
  }

  noteVisible(device: string, session: string): void {
    const key = JSON.stringify([device, session]);
    const row = this.visibleTargets.get(key);
    if (row === undefined) return;
    this.visibleTargets.delete(key);
    void this.markRead(row).catch(() => {});
  }

  async markRead(row: TeammateRosterEntry): Promise<void> {
    if (row.replyAt <= 0 || row.replyAt <= row.readAt) return;
    const request = this.request();
    const input: Record<string, Object> = {};
    input['at'] = Math.floor(row.replyAt);
    request['resourceRef'] = this.resourceRef(row.id);
    request['actionId'] = 'read';
    request['input'] = input;
    if (row.readAt >= 0) {
      await this.invoke(row.deviceId, 'maker:remote-resources:invoke', request);
    }
    const key = JSON.stringify([row.deviceId, row.id]);
    this.localReadAt.set(key, Math.max(this.localReadAt.get(key) ?? 0, row.replyAt));
    const change: Record<string, Object> = {};
    change['collectionId'] = 'teammates';
    this.changed(row.deviceId, change);
  }

  private resourceRef(id: string): Record<string, Object> {
    const ref: Record<string, Object> = {};
    ref['collectionId'] = 'teammates';
    ref['kind'] = 'bot';
    ref['id'] = id;
    return ref;
  }

  private request(settings: boolean = false, includeCollection: boolean = true): Record<string, Object> {
    const request: Record<string, Object> = {};
    const client: Record<string, Object> = {};
    client['protocolVersion'] = 1;
    client['primitives'] = settings ? ['status', 'session-link', 'form'] : ['status', 'session-link', 'session-controls'];
    request['client'] = client;
    if (includeCollection) request['collectionId'] = 'teammates';
    return request;
  }

  private async invoke(device: string, channel: string, request: Record<string, Object>,
    preSend?: () => void): Promise<Object | undefined> {
    const revision = this.revision;
    await this.openLink(device);
    return await this.call(device, channel, [request], revision, preSend);
  }

  private async call(device: string, channel: string, args: Object[], revision: number,
    preSend?: () => void): Promise<Object | undefined> {
    const options = new DlInvokeOptions();
    options.channel = channel;
    options.args = args;
    options.timeoutMs = 10000;
    options.preSend = (): void => {
      if (this.revision !== revision) throw new Error('账号已切换');
      preSend?.();
    };
    const result = unwrapInvokeResult(await this.client.invoke(device, options));
    if (this.revision !== revision) throw new Error('账号已切换');
    return result;
  }
}
