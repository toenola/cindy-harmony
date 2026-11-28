import { WsAdapter } from '../../network/WsAdapter';
import { HelloPayload } from '../device-link/DlProtocol';
import { recordOrEmpty, readStr } from '../tasks/TaskModels';
import { sharedTaskError, SharedTasksHost, SharedTaskRequest, SharedTaskHostCommand, SharedTaskInvitation,
  SharedTaskDetail, SharedTaskGuestTransport, SharedTaskJoinBody, SharedTaskFault, sharedTaskId } from './SharedTaskModels';
import { parseOfficialSharedTaskInvitation, buildOfficialSharedTaskInvitation, sharedTaskInvitationServer } from './SharedTaskInvitation';
import { SharedTaskGuestClientPorts, SharedTaskMediaPorts, SharedTaskReadyTransport, createSharedTaskGuestClient } from './SharedTaskGuestClient';

export interface SharedTaskAuthenticatedRequest {
  baseUrl: string; method: string; body?: Object; cache: string; timeoutMs: number; assertCurrent: () => void;
}
export interface SharedTaskAgentNetAdapter {
  parseInvitation: (input: string) => SharedTaskInvitation | null;
  // Null explicitly means no pinned AN authority owns the route; errors must NOT fall back to official.
  request: (path: string, options: SharedTaskRequest) => Promise<Object | null>;
  join: (invitation: SharedTaskInvitation, displayName: string, current: () => boolean) => Promise<Object | undefined>;
  owns: (sharedTaskId: string) => boolean;
  open: (detail: SharedTaskDetail) => Promise<SharedTaskReadyTransport>;
  invitationLink: (token: string, detail: SharedTaskDetail) => string;
  dispose: () => void;
}
export interface SharedTasksHostOptions {
  officialApiBase: string;
  officialWsUrl: string;
  app: string;
  accountId: () => string;
  scope: () => string;
  // Inject existing AuthStore request. No token files, alternative login or independent auth cache.
  apiFetch: (path: string, options: SharedTaskAuthenticatedRequest) => Promise<Object | undefined>;
  ownerInvoke: (deviceId: string, channel: string, args: Object[]) => Promise<Object | undefined>;
  getToken: () => Promise<string | null>;
  getHello: () => HelloPayload;
  createOfficialWs: () => WsAdapter;
  refreshAuth: () => void;
  media: SharedTaskMediaPorts;
  openOwner: (detail: SharedTaskDetail) => Promise<void>;
  guestReady: (transport: SharedTaskReadyTransport) => void;
  agentNet?: SharedTaskAgentNetAdapter;
  allowOfficial?: () => boolean;
}
interface SharedTaskAuthorityRead { value: Object | null; error: Object | null; }
class ActualSharedTasksHost implements SharedTasksHost {
  private options: SharedTasksHostOptions;
  private base: string;
  private closed: boolean = false;
  private guests: Set<SharedTaskReadyTransport> = new Set();
  private officialIds: Set<string> = new Set();
  private observedScope: string = '';
  constructor(options: SharedTasksHostOptions) {
    const base = sharedTaskInvitationServer(options.officialApiBase);
    if (!base) throw new SharedTaskFault('invalid');
    this.options = options; this.base = base;
  }
  private guard(scope: string): void {
    if (this.closed || !scope || scope !== this.options.scope() || !this.options.accountId()) throw new SharedTaskFault('ACCESS_REVOKED');
    if (scope !== this.observedScope) { this.guests.forEach((guest: SharedTaskReadyTransport): void => guest.close()); this.guests.clear(); this.officialIds.clear(); this.observedScope = scope; }
  }
  private async official(path: string, options: SharedTaskRequest): Promise<Object | undefined> {
    const scope = this.options.scope(); this.guard(scope);
    if (this.options.allowOfficial?.() === false) throw new SharedTaskFault('unsupported');
    if (!/^\/api\/device-link\/shared-tasks(?:\/[A-Za-z0-9._:%-]+)*(?:\/)?$/.test(path)
      || /(?:^|\/)\.\.?(?:\/|$)/.test(decodeURIComponent(path)) || !['GET', 'POST'].includes(options.method)) throw new SharedTaskFault('invalid');
    const request: SharedTaskAuthenticatedRequest = { baseUrl: this.base, method: options.method,
      cache: 'no-store', timeoutMs: 12000, assertCurrent: (): void => { this.guard(scope); if (!options.isCurrent()) throw new SharedTaskFault('ACCESS_REVOKED'); } };
    if (options.body !== undefined) request.body = options.body;
    request.assertCurrent();
    try {
      const value = await this.options.apiFetch(path, request);
      request.assertCurrent(); return value;
    } catch (error) { request.assertCurrent(); throw sharedTaskError(error); }
  }
  private async capture(work: Promise<Object | null | undefined>): Promise<SharedTaskAuthorityRead> {
    try { return { value: await work ?? null, error: null }; }
    catch (error) { return { value: null, error: error as Object }; }
  }
  async request(path: string, options: SharedTaskRequest): Promise<Object | undefined> {
    const scope = this.options.scope(); this.guard(scope);
    const agent = this.options.agentNet;
    if (agent && path === '/api/device-link/shared-tasks' && options.method === 'GET') {
      const reads: Array<Promise<SharedTaskAuthorityRead>> = [];
      if (this.options.allowOfficial?.() !== false) reads.push(this.capture(this.official(path, options)));
      reads.push(this.capture(agent.request(path, options)));
      const results = await Promise.all(reads); this.guard(scope);
      if (!options.isCurrent()) throw new SharedTaskFault('ACCESS_REVOKED');
      const items: Object[] = [], unavailable: string[] = [], ids: Set<string> = new Set();
      let incomplete = false, replied = false;
      for (let resultIndex = 0; resultIndex < results.length; resultIndex++) {
        const result = results[resultIndex];
        if (result.error) { incomplete = true; continue; }
        if (result.value === null) continue;
        replied = true; const row = recordOrEmpty(result.value);
        if (!Array.isArray(row['sharedTasks'])) throw new SharedTaskFault('invalid');
        for (const value of row['sharedTasks'] as Object[]) {
          const id = sharedTaskId(readStr(recordOrEmpty(value), 'sharedTaskId'));
          if (ids.has(id)) throw new SharedTaskFault('AGENT_NET_SHARING_ROUTE_CONFLICT');
          ids.add(id); items.push(value);
          if (resultIndex === 0 && this.options.allowOfficial?.() !== false) this.officialIds.add(id);
        }
        if (Array.isArray(row['unavailableSharedTaskIds'])) unavailable.push(...row['unavailableSharedTaskIds'] as string[]);
        if (row['authorityIncomplete'] === true) incomplete = true;
      }
      if (!replied) throw sharedTaskError(results[0]?.error ?? results[1]?.error ?? undefined);
      const response: Record<string, Object> = {}; response['sharedTasks'] = items; response['unavailableSharedTaskIds'] = unavailable;
      if (incomplete) response['authorityIncomplete'] = true; return response;
    }
    if (agent) {
      const result = await agent.request(path, options); this.guard(scope);
      if (result !== null) return result;
    }
    return this.official(path, options);
  }
  async ownerInvoke(deviceId: string, command: SharedTaskHostCommand): Promise<Object | undefined> {
    const scope = this.options.scope(); this.guard(scope);
    const value = await this.options.ownerInvoke(deviceId, 'maker:shared-task', [command]);
    this.guard(scope);
    if (this.options.agentNet && ['open', 'invite'].includes(command.action)) {
      const request: SharedTaskRequest = { method: 'GET', isCurrent: (): boolean => this.options.scope() === scope && !!this.options.accountId() };
      await this.request('/api/device-link/shared-tasks', request); this.guard(scope);
    }
    return value;
  }
  parseInvitation(input: string): SharedTaskInvitation | null {
    const agent = this.options.agentNet?.parseInvitation(input);
    return agent ?? parseOfficialSharedTaskInvitation(input, this.base);
  }
  async join(invitation: SharedTaskInvitation, displayName: string, isCurrent: () => boolean): Promise<Object | undefined> {
    const scope = this.options.scope(); this.guard(scope);
    if (invitation.kind === 'agent-net') {
      if (!this.options.agentNet) throw new SharedTaskFault('unsupported');
      const result = await this.options.agentNet.join(invitation, displayName, isCurrent); this.guard(scope); return result;
    }
    if (invitation.kind !== 'official' || invitation.server !== this.base) throw new SharedTaskFault('different-server');
    const body: SharedTaskJoinBody = { invitation: invitation.invitation, displayName };
    const request: SharedTaskRequest = { method: 'POST', body, isCurrent };
    return this.official('/api/device-link/shared-tasks/join', request);
  }
  async openGuest(detail: SharedTaskDetail): Promise<SharedTaskGuestTransport> {
    const scope = this.options.scope(); this.guard(scope);
    if (detail.status !== 'active' || detail.ownerAccountId === this.options.accountId()) throw new SharedTaskFault('forbidden');
    const agent = this.options.agentNet;
    let transport: SharedTaskReadyTransport;
    if (agent?.owns(detail.sharedTaskId)) transport = await agent.open(detail);
    else {
      if (this.options.allowOfficial?.() === false) throw new SharedTaskFault('unsupported');
      const member = detail.guests.find((guest): boolean => guest.accountId === this.options.accountId());
      if (!member) throw new SharedTaskFault('ACCESS_REVOKED');
      sharedTaskId(member.memberId);
      const ports: SharedTaskGuestClientPorts = { accountId: this.options.accountId(), wsUrl: this.options.officialWsUrl,
        getToken: this.options.getToken, getHello: this.options.getHello, createWs: this.options.createOfficialWs,
        current: (): boolean => this.options.scope() === scope && !!this.options.accountId(), refreshAuth: this.options.refreshAuth,
        media: this.options.media, transport: 'official-scoped' };
      transport = await createSharedTaskGuestClient(detail, member.memberId, ports);
    }
    try { this.guard(scope); this.guests.add(transport); transport.onClosed((): void => { this.guests.delete(transport); }); this.options.guestReady(transport); return transport; }
    catch (error) { transport.close(); throw sharedTaskError(error); }
  }
  async openOwner(detail: SharedTaskDetail): Promise<void> {
    const scope = this.options.scope(); this.guard(scope);
    if (detail.ownerAccountId !== this.options.accountId()) throw new SharedTaskFault('forbidden');
    await this.options.openOwner(detail); this.guard(scope);
  }
  dispose(): void { this.closed = true; this.guests.forEach((guest: SharedTaskReadyTransport): void => guest.close()); this.guests.clear(); this.options.agentNet?.dispose(); }
  invitationLink(token: string, detail: SharedTaskDetail): string {
    if (this.options.agentNet?.owns(detail.sharedTaskId)) return this.options.agentNet.invitationLink(token, detail);
    if (this.options.agentNet && !this.officialIds.has(detail.sharedTaskId)) throw new SharedTaskFault('unsupported');
    return buildOfficialSharedTaskInvitation(token, this.base, this.options.app);
  }
}
export function createSharedTasksHost(options: SharedTasksHostOptions): SharedTasksHost { return new ActualSharedTasksHost(options); }
