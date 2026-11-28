import { WsAdapter, WsCallbacks, WsMessage } from '../../network/WsAdapter';
import { HelloPayload } from '../device-link/DlProtocol';
import { recordOrEmpty, readStr, readNum } from '../tasks/TaskModels';
import { sharedTaskError, SharedTaskInvitation, SharedTaskRequest, SharedTaskDetail, SharedTaskJoinBody, SharedTaskFault, sharedTaskId } from './SharedTaskModels';
import { SharedTaskAgentNetAdapter } from './SharedTasksHost';
import { SharedTaskGuestClientPorts, SharedTaskMediaPorts, SharedTaskReadyTransport, SharedTaskAgentNetMedia, createSharedTaskGuestClient } from './SharedTaskGuestClient';

export interface SharedAgentNetRoute {
  v: number; server: string; networkId: string; rootPublicKey: string; hostDeviceId: string;
  resourceId: string; kind: string; region: string; memberId: string; retired: boolean; keyId?: string; privateMember?: boolean; subject?: string;
}
export interface SharedAgentNetConfig extends SharedAgentNetRoute { accountId: string; deviceId: string; localRegion: string; }
export interface SharedAgentNetOrigin { v: number; server: string; networkId: string; rootPublicKey: string; region: string; privateMember: boolean; subject: string; }
export interface SharingWireCallbacks { open: () => void; message: (data: string, binary: boolean) => void; close: (code: number) => void; error: () => void; }
export interface SharingWireSocket { send: (data: string, binary: boolean) => void; close: () => void; }
export interface SharingNativeHost {
  check: () => void;
  // Named native engines initialized under the actual account, source root and task-specific secure seed handles.
  command: (engine: string, input: string) => string;
  sha256: (base64url: string) => string;
  identityCard: (nonce: string) => Promise<string>;
  memberAuthorization: (method: string, path: string, body: string) => Promise<string>;
  request: (address: string, method: string, headers: string, body: string, binary: boolean) => Promise<string>;
  socket: (address: string, headers: string, callbacks: SharingWireCallbacks) => SharingWireSocket;
  message: (text: string) => void;
  close: (code: number) => void;
  error: () => void;
  destroyEngine: (engine: string) => void;
  destroy: () => void;
}
export interface AgentNetSharingConnection extends SharedTaskAgentNetMedia {
  request: (path: string, method: string, body: string, timeoutMs?: number) => Promise<string>;
  subject: () => string;
  connect: () => Promise<void>;
  deleteMedia?: (key: string) => Promise<void>;
  send: (text: string) => void;
  close: () => void;
}
/** Actual exports of owned portable/SharingBridge.mjs (bundle with its build.mjs). */
export interface AgentNetSharingBridge {
  parseSharingInvitation: (input: string) => string;
  buildSharingInvitation: (receipt: string, server: string, app: string) => string;
  createAgentNetSharing: (config: string, host: SharingNativeHost) => Promise<AgentNetSharingConnection>;
}
export interface SharedTaskAgentNetPorts {
  bridge: AgentNetSharingBridge;
  scope: () => string;
  accountId: () => string;
  deviceId: () => string;
  region: () => string;
  app: string;
  getHello: () => HelloPayload;
  media: SharedTaskMediaPorts;
  createNative: (config: SharedAgentNetConfig, current: () => boolean) => Promise<SharingNativeHost>;
  // Metadata only; signer seeds belong exclusively in the host's existing secure storage.
  randomKeyId: () => string;
  accountOrigin?: () => SharedAgentNetOrigin | null;
  accountOrigins?: () => SharedAgentNetOrigin[];
  loadRoutes: (scope: string) => Promise<SharedAgentNetRoute[]>;
  saveRoutes: (scope: string, routes: SharedAgentNetRoute[]) => Promise<void>;
}
class SharingText implements WsMessage {
  private text: string;
  constructor(text: string) { this.text = text; }
  toString(): string { return this.text; }
}
export class AgentNetSharingSocket implements WsAdapter {
  private ports: SharedTaskAgentNetPorts;
  private config: SharedAgentNetConfig;
  private current: () => boolean;
  private callbacks: WsCallbacks = new WsCallbacks();
  private connection: AgentNetSharingConnection | null = null;
  private native: SharingNativeHost | null = null;
  private closed: boolean = false;
  constructor(ports: SharedTaskAgentNetPorts, config: SharedAgentNetConfig, current: () => boolean) { this.ports = ports; this.config = config; this.current = current; }
  setCallbacks(callbacks: WsCallbacks): void { this.callbacks = callbacks; }
  connect(_address: string, _headers: Record<string, string>): void {
    void this.open().catch((error: Object): void => {
      const notify = !this.closed && this.current(); this.close();
      if (notify) { this.callbacks.onError(error instanceof Error ? error : new Error('AGENT_NET_SHARING_FAILED')); this.callbacks.onClose(1006, 'sharing-unavailable'); }
    });
  }
  private async open(): Promise<void> {
    const native = await this.ports.createNative(this.config, this.current);
    if (this.closed || !this.current()) { native.destroy(); return; }
    native.message = (text: string): void => { if (!this.closed && this.current()) this.callbacks.onMessage(new SharingText(text)); };
    native.close = (code: number): void => { if (!this.closed && this.current()) { this.close(); this.callbacks.onClose(code, 'sharing-connection-closed'); } };
    native.error = (): void => { if (!this.closed && this.current()) this.callbacks.onError(new Error('AGENT_NET_SHARING_NETWORK_ERROR')); };
    this.native = native;
    const connection = await this.ports.bridge.createAgentNetSharing(JSON.stringify(this.config), native);
    if (this.closed || !this.current()) { connection.close(); this.close(); return; }
    this.connection = connection; await connection.connect();
    if (this.closed || !this.current()) { this.close(); return; }
    this.callbacks.onOpen();
  }
  async upload(size: number, contentType: string, read: (offset: number, length: number) => Promise<string>): Promise<string> {
    if (this.closed || !this.current() || !this.connection) throw new SharedTaskFault('ACCESS_REVOKED');
    const result = await this.connection.upload(size, contentType, read);
    if (this.closed || !this.current()) throw new SharedTaskFault('ACCESS_REVOKED'); return result;
  }
  async download(key: string, write: (base64url: string, offset: number) => Promise<void>): Promise<string> {
    if (this.closed || !this.current() || !this.connection) throw new SharedTaskFault('ACCESS_REVOKED');
    const result = await this.connection.download(key, write);
    if (this.closed || !this.current()) throw new SharedTaskFault('ACCESS_REVOKED'); return result;
  }
  async deleteMedia(key: string): Promise<void> {
    if (this.closed || !this.current()) throw new SharedTaskFault('ACCESS_REVOKED');
    if (!this.connection?.deleteMedia) throw new SharedTaskFault('unsupported');
    await this.connection.deleteMedia(key);
    if (this.closed || !this.current()) throw new SharedTaskFault('ACCESS_REVOKED');
  }
  send(text: string): boolean { if (this.closed || !this.current() || !this.connection) return false; this.connection.send(text); return true; }
  close(_code?: number, _reason?: string): void { this.closed = true; this.connection?.close(); this.connection = null; this.native?.destroy(); this.native = null; }
  terminate(): void { this.close(); }
}
function routeKey(route: SharedAgentNetRoute): string { return JSON.stringify([route.v, route.server, route.networkId, route.rootPublicKey, route.hostDeviceId, route.resourceId]); }
class ActualAgentNetSharing implements SharedTaskAgentNetAdapter {
  private ports: SharedTaskAgentNetPorts;
  private routes: SharedAgentNetRoute[] = [];
  private owner: string = '';
  private loaded: Promise<void> | null = null;
  private business: Map<string, Promise<AgentNetSharingConnection>> = new Map();
  private disposed: boolean = false;
  private guests: Set<SharedTaskReadyTransport> = new Set();
  private writes: Promise<void> = Promise.resolve();
  constructor(ports: SharedTaskAgentNetPorts) { this.ports = ports; }
  private current(scope: string): boolean { return !this.disposed && !!scope && scope === this.ports.scope() && !!this.ports.accountId(); }
  private async load(): Promise<void> {
    const scope = this.ports.scope();
    if (scope !== this.owner) {
      this.business.forEach((value: Promise<AgentNetSharingConnection>): void => { void value.then((connection: AgentNetSharingConnection): void => connection.close()).catch((): void => {}); });
      this.business.clear(); this.routes = []; this.owner = scope; this.loaded = null;
    }
    if (!this.current(scope)) throw new SharedTaskFault('ACCESS_REVOKED');
    if (!this.loaded) {
      const loading = this.ports.loadRoutes(scope).then((routes: SharedAgentNetRoute[]): void => {
        if (!this.current(scope)) throw new SharedTaskFault('ACCESS_REVOKED');
        if (routes.length > 1024) throw new SharedTaskFault('invalid');
        const seen: Set<string> = new Set();
        for (const route of routes) {
          this.validate(route);
          if (seen.has(route.resourceId)) throw new SharedTaskFault('invalid'); seen.add(route.resourceId);
        }
        this.routes = routes.slice();
      }).catch((error: Object): void => { if (this.loaded === loading) this.loaded = null; throw sharedTaskError(error); });
      this.loaded = loading;
    }
    await this.loaded;
  }
  private validate(route: SharedAgentNetRoute): void {
    // Reuse the exact fixed upstream receipt validator without retaining invitation secrets.
    const receipt: Record<string, Object> = {};
    receipt['v'] = route.v; receipt['kind'] = 'shared-task'; receipt['invitation'] = 'A'.repeat(43);
    receipt['networkId'] = route.networkId; receipt['rootPublicKey'] = route.rootPublicKey;
    receipt['resourceId'] = route.resourceId; receipt['hostDeviceId'] = route.hostDeviceId; receipt['region'] = route.region;
    const link = this.ports.bridge.buildSharingInvitation(JSON.stringify(receipt), route.server, this.ports.app);
    if (!this.ports.bridge.parseSharingInvitation(link) || route.kind !== 'shared-task') throw new SharedTaskFault('invalid');
    if (route.memberId) { sharedTaskId(route.memberId); if (!route.keyId || !/^[A-Za-z0-9_-]{24}$/.test(route.keyId)) throw new SharedTaskFault('AGENT_NET_SHARING_SEED_UNAVAILABLE'); }
  }
  private origins(): SharedAgentNetOrigin[] {
    if (this.ports.accountOrigins) return this.ports.accountOrigins();
    const origin = this.ports.accountOrigin?.(); return origin ? [origin] : [];
  }
  private config(route: SharedAgentNetRoute): SharedAgentNetConfig {
    const origin = this.origins().find((candidate: SharedAgentNetOrigin): boolean => candidate.v === route.v && candidate.server === route.server
      && candidate.networkId === route.networkId && candidate.rootPublicKey === route.rootPublicKey);
    const privateMember = !!origin?.privateMember && origin.server === route.server && origin.networkId === route.networkId && origin.rootPublicKey === route.rootPublicKey;
    return { v: route.v, server: route.server, networkId: route.networkId, rootPublicKey: route.rootPublicKey,
      hostDeviceId: route.hostDeviceId, resourceId: route.resourceId, kind: route.kind, region: route.region,
      memberId: route.memberId, retired: route.retired, keyId: route.keyId, privateMember, subject: privateMember ? origin?.subject ?? '' : '', accountId: this.ports.accountId(), deviceId: this.ports.deviceId(), localRegion: this.ports.region() };
  }
  private connection(route: SharedAgentNetRoute): Promise<AgentNetSharingConnection> {
    const config = this.config(route), key = routeKey(route) + JSON.stringify([config.privateMember ?? false, config.subject ?? '']);
    const saved = this.business.get(key); if (saved) return saved;
    const scope = this.ports.scope();
    const pending = this.ports.createNative(config, (): boolean => this.current(scope)).then(async (native: SharingNativeHost): Promise<AgentNetSharingConnection> => {
      if (!this.current(scope)) { native.destroy(); throw new SharedTaskFault('ACCESS_REVOKED'); }
      try {
        const connection = await this.ports.bridge.createAgentNetSharing(JSON.stringify(config), native);
        if (!this.current(scope)) { connection.close(); native.destroy(); throw new SharedTaskFault('ACCESS_REVOKED'); }
        return connection;
      } catch (error) { native.destroy(); throw sharedTaskError(error); }
    }).catch((error: Object): AgentNetSharingConnection => { if (this.business.get(key) === pending) this.business.delete(key); throw sharedTaskError(error); });
    this.business.set(key, pending); return pending;
  }
  parseInvitation(input: string): SharedTaskInvitation | null {
    const raw = this.ports.bridge.parseSharingInvitation(input);
    if (!raw) return null;
    const parsed = recordOrEmpty(JSON.parse(raw) as Object), receipt = recordOrEmpty(parsed['receipt']);
    return { kind: 'agent-net', invitation: raw, server: readStr(parsed, 'server'), sharedTaskId: readStr(receipt, 'resourceId') };
  }
  owns(id: string): boolean { return this.owner === this.ports.scope() && this.routes.some((route: SharedAgentNetRoute): boolean => route.resourceId === id); }
  private async save(route: SharedAgentNetRoute): Promise<void> {
    const scope = this.ports.scope();
    const write = this.writes.then(async (): Promise<void> => {
      if (!this.current(scope)) throw new SharedTaskFault('ACCESS_REVOKED');
      const old = this.routes.find((candidate: SharedAgentNetRoute): boolean => candidate.resourceId === route.resourceId);
      if (old && routeKey(old) !== routeKey(route)) throw new SharedTaskFault('AGENT_NET_SHARING_ROUTE_CONFLICT');
      const next = this.routes.filter((candidate: SharedAgentNetRoute): boolean => candidate.resourceId !== route.resourceId).concat([route]);
      if (next.length > 1024) throw new SharedTaskFault('invalid');
      await this.ports.saveRoutes(scope, next);
      if (!this.current(scope)) throw new SharedTaskFault('ACCESS_REVOKED'); this.routes = next;
    });
    this.writes = write.catch((): void => {}); await write;
  }
  async join(invitation: SharedTaskInvitation, displayName: string, current: () => boolean): Promise<Object | undefined> {
    await this.load(); const scope = this.ports.scope();
    if (!current()) throw new SharedTaskFault('ACCESS_REVOKED');
    const parsed = recordOrEmpty(JSON.parse(invitation.invitation) as Object), raw = recordOrEmpty(parsed['receipt']);
    const route: SharedAgentNetRoute = { v: readNum(raw, 'v', 0), server: readStr(parsed, 'server'), networkId: readStr(raw, 'networkId'),
      rootPublicKey: readStr(raw, 'rootPublicKey'), hostDeviceId: readStr(raw, 'hostDeviceId'), resourceId: readStr(raw, 'resourceId'),
      kind: readStr(raw, 'kind'), region: readStr(raw, 'region'), memberId: '', retired: false };
    this.validate(route);
    const origin = this.ports.accountOrigin?.();
    if (route.v === 3 && origin?.networkId === route.networkId && origin.rootPublicKey === route.rootPublicKey && origin.privateMember) throw new SharedTaskFault('SHARED_TASK_SELF_JOIN');
    const previous = this.routes.find((candidate: SharedAgentNetRoute): boolean => candidate.resourceId === route.resourceId);
    if (previous && routeKey(previous) !== routeKey(route)) throw new SharedTaskFault('AGENT_NET_SHARING_ROUTE_CONFLICT');
    const token = readStr(raw, 'invitation'); if (!/^[A-Za-z0-9_-]{43}$/.test(token)) throw new SharedTaskFault('invitation');
    const body: SharedTaskJoinBody = { invitation: token, displayName };
    const connection = await this.connection(route);
    const result = recordOrEmpty(JSON.parse(await connection.request('/api/device-link/shared-tasks/join', 'POST', JSON.stringify(body))) as Object);
    if (!this.current(scope) || !current()) throw new SharedTaskFault('ACCESS_REVOKED');
    if (readStr(result, 'sharedTaskId') !== route.resourceId || result['status'] !== 'joined' || typeof result['created'] !== 'boolean') throw new SharedTaskFault('invalid');
    route.memberId = sharedTaskId(readStr(result, 'memberId'));
    route.keyId = previous?.memberId === route.memberId && !previous.retired ? previous.keyId : this.ports.randomKeyId();
    this.validate(route); await this.save(route); return result;
  }
  async request(path: string, options: SharedTaskRequest): Promise<Object | null> {
    await this.load(); const scope = this.ports.scope();
    if (!options.isCurrent()) throw new SharedTaskFault('ACCESS_REVOKED');
    const match = /^\/api\/device-link\/shared-tasks\/([^/]+)/.exec(path);
    if (!match) {
      if (path !== '/api/device-link/shared-tasks' || options.method !== 'GET' || (!this.routes.length && !this.origins().length)) return null;
      const items: Object[] = [], unavailable: string[] = [], origins: Set<string> = new Set();
      const sources: SharedAgentNetRoute[] = [];
      for (const origin of this.origins()) {
        const source: SharedAgentNetRoute = { v: origin.v, server: origin.server, networkId: origin.networkId, rootPublicKey: origin.rootPublicKey,
          hostDeviceId: '', resourceId: '', kind: 'shared-task', region: origin.region, memberId: '', retired: false,
          privateMember: origin.privateMember, subject: origin.subject };
        sources.push(source); origins.add(JSON.stringify([source.v, source.server, source.networkId, source.rootPublicKey]));
      }
      for (const route of this.routes) {
        const key = JSON.stringify([route.v, route.server, route.networkId, route.rootPublicKey]);
        if (!origins.has(key) && !route.retired) { origins.add(key); sources.push(route); }
      }
      const deadline = Date.now() + 12000;
      let cursor = 0, incomplete = false;
      const worker = async (): Promise<void> => {
        while (cursor < sources.length) {
          const route = sources[cursor++];
          try {
            if (Date.now() >= deadline) throw new SharedTaskFault('failed');
            const connection = await this.connection(route);
            const reply = recordOrEmpty(JSON.parse(await connection.request(path, 'GET', '', Math.max(1, deadline - Date.now()))) as Object);
            if (!this.current(scope) || !options.isCurrent()) throw new SharedTaskFault('ACCESS_REVOKED');
            if (!Array.isArray(reply['sharedTasks'])) throw new SharedTaskFault('invalid');
            for (const item of reply['sharedTasks'] as Object[]) {
              const id = readStr(recordOrEmpty(item), 'sharedTaskId');
              const rawItem = recordOrEmpty(item), old = this.routes.find((candidate: SharedAgentNetRoute): boolean => candidate.resourceId === id);
              const discovered: SharedAgentNetRoute = { v: route.v, server: route.server, networkId: route.networkId, rootPublicKey: route.rootPublicKey,
                resourceId: sharedTaskId(id), hostDeviceId: readStr(rawItem, 'hostDeviceId'), kind: 'shared-task', region: route.region,
                memberId: old?.memberId ?? '', retired: old?.retired ?? false, keyId: old?.keyId, privateMember: route.privateMember, subject: route.subject };
              this.validate(discovered); await this.save(discovered);
              if (readStr(rawItem, 'ownerAccountId') === connection.subject()) rawItem['ownerAccountId'] = this.ports.accountId();
              if (!discovered.retired) items.push(rawItem);
            }
          } catch (error) {
            if (!this.current(scope) || !options.isCurrent()) throw sharedTaskError(error);
            incomplete = true;
            unavailable.push(...this.routes.filter((candidate: SharedAgentNetRoute): boolean => candidate.server === route.server
              && candidate.rootPublicKey === route.rootPublicKey).map((candidate: SharedAgentNetRoute): string => candidate.resourceId));
          }
        }
      };
      const workers: Array<Promise<void>> = [];
      for (let index = 0; index < Math.min(4, sources.length); index++) workers.push(worker());
      await Promise.all(workers);
      const result: Record<string, Object> = {}; result['sharedTasks'] = items; result['unavailableSharedTaskIds'] = unavailable;
      if (incomplete) result['authorityIncomplete'] = true; return result;
    }
    const id = decodeURIComponent(match[1]), route = this.routes.find((candidate: SharedAgentNetRoute): boolean => candidate.resourceId === id);
    if (!route) return null;
    if (route.retired) throw new SharedTaskFault('ACCESS_REVOKED');
    const connection = await this.connection(route);
    const raw = await connection.request(path, options.method, options.body === undefined ? '' : JSON.stringify(options.body));
    if (!this.current(scope) || !options.isCurrent()) throw new SharedTaskFault('ACCESS_REVOKED');
    const value = recordOrEmpty(JSON.parse(raw) as Object);
    if (path.endsWith('/leave')) { route.retired = true; await this.save(route); }
    else if (options.method === 'GET' && /^\/api\/device-link\/shared-tasks\/[^/]+$/.test(path)) {
      if (readStr(value, 'sharedTaskId') !== route.resourceId || readStr(value, 'hostDeviceId') !== route.hostDeviceId) throw new SharedTaskFault('AGENT_NET_SHARING_ROUTE_CONFLICT');
      const subject = connection.subject();
      if (readStr(value, 'ownerAccountId') === subject) value['ownerAccountId'] = this.ports.accountId();
      else if (!route.memberId && Array.isArray(value['guests'])) {
        for (const rawGuest of value['guests'] as Object[]) {
          const guest = recordOrEmpty(rawGuest);
          if (readStr(guest, 'accountId') === subject) { route.memberId = sharedTaskId(readStr(guest, 'memberId')); route.keyId = this.ports.randomKeyId(); this.validate(route); await this.save(route); break; }
        }
      }
    }
    return value;
  }
  async open(detail: SharedTaskDetail): Promise<SharedTaskReadyTransport> {
    await this.load(); const scope = this.ports.scope();
    const route = this.routes.find((candidate: SharedAgentNetRoute): boolean => candidate.resourceId === detail.sharedTaskId);
    if (!route || route.retired || route.hostDeviceId !== detail.hostDeviceId || !route.memberId) throw new SharedTaskFault('ACCESS_REVOKED');
    const config = this.config(route);
    const current = (): boolean => this.current(scope) && !route.retired && this.routes.some((candidate: SharedAgentNetRoute): boolean => candidate.memberId === route.memberId && routeKey(candidate) === routeKey(route) && !candidate.retired);
    let socket: AgentNetSharingSocket | null = null;
    const ports: SharedTaskGuestClientPorts = { accountId: this.ports.accountId(), wsUrl: route.server.replace(/^http/, 'ws') + '/api/agent-net/guest/ws',
      getToken: async (): Promise<string> => 'agent-net-scoped-native', getHello: this.ports.getHello,
      createWs: (): WsAdapter => { socket = new AgentNetSharingSocket(this.ports, config, current); return socket; }, current, refreshAuth: (): void => {}, media: this.ports.media, transport: 'agent-net' };
    const guest = await createSharedTaskGuestClient(detail, route.memberId, ports); this.guests.add(guest);
    const media: SharedTaskAgentNetMedia = {
      upload: async (size: number, mime: string, read: (offset: number, length: number) => Promise<string>): Promise<string> => {
        if (!socket) throw new SharedTaskFault('unsupported'); return socket.upload(size, mime, read);
      },
      download: async (key: string, write: (base64url: string, offset: number) => Promise<void>): Promise<string> => {
        if (!socket) throw new SharedTaskFault('unsupported'); return socket.download(key, write);
      },
      delete: async (key: string): Promise<void> => {
        if (!socket) throw new SharedTaskFault('unsupported'); await socket.deleteMedia(key);
      }
    };
    guest.agentNetMedia = media;
    guest.onClosed((): void => { this.guests.delete(guest); }); return guest;
  }
  dispose(): void {
    this.disposed = true; this.guests.forEach((guest: SharedTaskReadyTransport): void => guest.close()); this.guests.clear();
    this.business.forEach((value: Promise<AgentNetSharingConnection>): void => { void value.then((connection: AgentNetSharingConnection): void => connection.close()).catch((): void => {}); });
    this.business.clear(); this.routes = [];
  }
  invitationLink(token: string, detail: SharedTaskDetail): string {
    const route = this.routes.find((candidate: SharedAgentNetRoute): boolean => candidate.resourceId === detail.sharedTaskId);
    if (!route) throw new SharedTaskFault('unsupported');
    const receipt: Record<string, Object> = {};
    receipt['v'] = route.v; receipt['kind'] = 'shared-task'; receipt['invitation'] = token; receipt['networkId'] = route.networkId;
    receipt['rootPublicKey'] = route.rootPublicKey; receipt['resourceId'] = route.resourceId; receipt['hostDeviceId'] = route.hostDeviceId; receipt['region'] = route.region;
    return this.ports.bridge.buildSharingInvitation(JSON.stringify(receipt), route.server, this.ports.app);
  }
}
export function createSharedTaskAgentNetAdapter(ports: SharedTaskAgentNetPorts): SharedTaskAgentNetAdapter { return new ActualAgentNetSharing(ports); }
