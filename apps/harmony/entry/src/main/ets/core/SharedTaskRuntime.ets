import { registerScopedAttachments } from './attachments/ScopedAttachmentRoutes';
import { common } from '@kit.AbilityKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { AppConfig } from '../AppConfig';
import { HarmonyWsAdapter } from '../network/HarmonyWsAdapter';
import { HarmonyHttp } from '../network/HarmonyHttp';
import { AuthStore } from './auth/AuthStore';
import { SecureStore } from './storage/SecureStore';
import { HelloPayload } from './device-link/DlProtocol';
import { DlClient } from './device-link/DlClient';
import { base64Url } from './device-link/AgentNetPairing';
import { SharedTasksStore } from './shared-tasks/SharedTasksStore';
import { SharedTaskDetail, SharedTasksHost, SharedTaskSessionTarget, SharedTaskFault } from './shared-tasks/SharedTaskModels';
import { SharedTaskReadyTransport } from './shared-tasks/SharedTaskGuestClient';
import { createSharedTasksHost, SharedTasksHostOptions, SharedTaskAuthenticatedRequest } from './shared-tasks/SharedTasksHost';
import { createSharedTaskMediaPorts, SharedTaskMedia } from './shared-tasks/SharedTaskMedia';
import { HarmonySharingNative, sharingParseUrl, sharingQueryPairs } from './shared-tasks/HarmonySharingNative';
import { createSharedTaskAgentNetAdapter, SharedTaskAgentNetPorts, SharedAgentNetConfig } from './shared-tasks/SharedTaskAgentNet';
import * as sharing from './shared-tasks/portable/sharing';

class SharedTaskHttpFailure extends SharedTaskFault {
  status: number;
  constructor(status: number, code: string) { super(code); this.status = status; }
}
export interface SharedTaskRuntimePorts {
  auth: AuthStore; storage: SecureStore; client: DlClient; context: common.UIAbilityContext;
  getHello: () => HelloPayload;
  ownerInvoke: (device: string, channel: string, args: Object[]) => Promise<Object | undefined>;
  openOwner: (detail: SharedTaskDetail) => Promise<void>;
  ready: (guest: SharedTaskReadyTransport) => void;
  closed: (target: SharedTaskSessionTarget) => void;
}

/** Shared authorization is account-scoped and deliberately independent of the selected control relay. */
export class SharedTaskRuntime {
  readonly store: SharedTasksStore;
  readonly host: SharedTasksHost;
  private ports: SharedTaskRuntimePorts;
  private guests: Map<string, SharedTaskReadyTransport> = new Map();
  private media: SharedTaskMedia;
  private native: HarmonySharingNative;
  private owner: string;
  private stopped: boolean = false;
  private foreground: boolean = true;
  constructor(ports: SharedTaskRuntimePorts, deviceId: string) {
    this.ports = ports; this.owner = this.scope();
    this.media = createSharedTaskMediaPorts({ auth: ports.auth, context: ports.context,
      officialApiBase: AppConfig.deviceLinkApiBaseUrl, scope: (): string => this.scope(),
      readyGuest: (peer: string): SharedTaskReadyTransport | null => this.guests.get(peer) ?? null });
    sharing.installSharingWebApis(sharingParseUrl, sharingQueryPairs);
    const native = new HarmonySharingNative({ auth: ports.auth, secureStore: ports.storage, scope: (): string => this.scope() });
    this.native = native;
    const an: SharedTaskAgentNetPorts = { bridge: sharing, scope: (): string => this.scope(),
      accountId: (): string => ports.auth.cacheAccountId, deviceId: (): string => deviceId,
      region: (): string => AppConfig.region, app: AppConfig.region === 'cn' ? 'cindycn' : 'cindy',
      getHello: ports.getHello, media: this.media,
      createNative: (config: SharedAgentNetConfig, current: () => boolean) => native.create(config, current),
      randomKeyId: (): string => base64Url(cryptoFramework.createRandom().generateRandomSync(18).data),
      accountOrigin: () => native.accountOrigin(), accountOrigins: () => native.accountOrigins(),
      loadRoutes: (scope: string) => native.loadRoutes(scope), saveRoutes: (scope: string, routes) => native.saveRoutes(scope, routes) };
    const options: SharedTasksHostOptions = {
      officialApiBase: AppConfig.deviceLinkApiBaseUrl, officialWsUrl: AppConfig.deviceLinkWsUrl,
      app: AppConfig.region === 'cn' ? 'cindycn' : 'cindy', accountId: (): string => ports.auth.cacheAccountId,
      scope: (): string => this.scope(), apiFetch: (path: string, request: SharedTaskAuthenticatedRequest) => this.request(path, request),
      ownerInvoke: ports.ownerInvoke, getToken: (): Promise<string | null> => ports.auth.getAccessToken(),
      getHello: ports.getHello, createOfficialWs: (): HarmonyWsAdapter => new HarmonyWsAdapter(),
      refreshAuth: (): void => { void ports.auth.forceRefreshToken().catch((): void => {}); },
      media: this.media, openOwner: ports.openOwner, agentNet: createSharedTaskAgentNetAdapter(an),
      guestReady: (guest: SharedTaskReadyTransport): void => this.register(guest),
    };
    this.host = createSharedTasksHost(options); this.store = new SharedTasksStore(this.host); this.configure();
  }
  scope(): string {
    return !this.stopped && this.ports.auth.isLoggedIn && this.ports.auth.cacheAccountId
      ? JSON.stringify([AppConfig.region, this.ports.auth.cacheAccountId, this.ports.auth.sessionEpoch]) : '';
  }
  current(): boolean { return !!this.owner && this.owner === this.scope(); }
  configure(): void {
    this.store.configure(this.scope(), this.ports.auth.cacheAccountId, this.ports.auth.displayName, this.foreground && this.current());
  }
  setForeground(value: boolean): void { this.foreground = value; this.configure(); }
  guest(peer: string): SharedTaskReadyTransport | null { return this.current() ? this.guests.get(peer) ?? null : null; }
  private register(guest: SharedTaskReadyTransport): void {
    if (!this.current()) { guest.close(); throw new SharedTaskFault('ACCESS_REVOKED'); }
    const peer = guest.target.peer;
    this.guests.get(peer)?.close(); this.guests.set(peer, guest);
    this.ports.client.registerScopedPeer(peer, guest.scopedPort());
    const offMedia = registerScopedAttachments(peer, { current: (): boolean => this.current() && this.guests.get(peer) === guest && guest.scopedPort().current(),
      upload: (uri: string, name: string, mime: string): Promise<string> => guest.upload(uri, name, mime),
      fetch: (ref: string): Promise<Object | undefined> => guest.fetch(ref),
      delete: (key: string): Promise<void> => {
        if (!guest.delete) return Promise.reject(new SharedTaskFault('unsupported'));
        return guest.delete(key);
      } });
    guest.onClosed((): void => {
      if (this.guests.get(peer) !== guest) return;
      offMedia(); this.guests.delete(peer); this.ports.client.removeScopedPeer(peer); this.media.cleanup(peer); this.ports.closed(guest.target);
    });
    this.ports.ready(guest);
  }
  private async request(path: string, options: SharedTaskAuthenticatedRequest): Promise<Object | undefined> {
    options.assertCurrent();
    if (options.baseUrl !== AppConfig.deviceLinkApiBaseUrl || !path.startsWith('/api/device-link/shared-tasks')) throw new SharedTaskFault('forbidden');
    let token = await this.ports.auth.getAccessToken(); options.assertCurrent();
    if (!token) throw new SharedTaskFault('UNAUTHENTICATED');
    const headers: Record<string, string> = {}; headers['Authorization'] = 'Bearer ' + token;
    const http = new HarmonyHttp();
    const body = options.body === undefined ? undefined : JSON.stringify(options.body);
    let response = await http.requestJson(options.baseUrl + path, options.method === 'GET' ? 'GET' : 'POST', headers, body, 12000, true);
    options.assertCurrent();
    if (response.statusCode === 401) {
      token = await this.ports.auth.forceRefreshToken(); options.assertCurrent();
      if (!token) throw new SharedTaskFault('UNAUTHENTICATED'); headers['Authorization'] = 'Bearer ' + token;
      response = await http.requestJson(options.baseUrl + path, options.method === 'GET' ? 'GET' : 'POST', headers, body, 12000, true); options.assertCurrent();
    }
    if (response.statusCode >= 300) {
      let code = 'SHARED_TASK_REQUEST_FAILED';
      try {
        const row = JSON.parse(response.body) as Record<string, Object>, detail = row['error'] as Record<string, Object>;
        const value = detail?.['code'] ?? row['code']; if (typeof value === 'string') code = value;
      } catch (_error) {}
      throw new SharedTaskHttpFailure(response.statusCode, code);
    }
    if (response.body.length > 4 * 1024 * 1024) throw new SharedTaskFault('invalid');
    return response.body ? JSON.parse(response.body) as Object : undefined;
  }
  dispose(): void {
    if (this.stopped) return; this.stopped = true;
    this.store.dispose(); this.host.dispose?.(); this.guests.forEach((guest: SharedTaskReadyTransport): void => guest.close());
    this.guests.clear(); this.media.dispose(); this.native.dispose();
  }
}

/** Parsing an incoming URL cannot choose an authenticated request origin. */
export function parseSharedTaskLink(input: string): string {
  sharing.installSharingWebApis(sharingParseUrl, sharingQueryPairs);
  return sharing.parseSharingInvitation(input);
}
