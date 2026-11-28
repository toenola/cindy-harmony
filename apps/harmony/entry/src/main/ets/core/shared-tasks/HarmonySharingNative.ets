import { SecureStore } from '../storage/SecureStore';
import { SharingSeedStore } from './SharingSeedStore';
import { http, webSocket } from '@kit.NetworkKit';
import { util, url } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AuthStore } from '../auth/AuthStore';
import { AppConfig } from '../../AppConfig';
import { HarmonyHttp } from '../../network/HarmonyHttp';
import { AgentNetEngine, AgentNetEngineOptions } from '../device-link/AgentNetEngine';
import { base64Url } from '../device-link/AgentNetPairing';
import { RelayRoute } from '../device-link/RelayRoute';
import { recordOrEmpty, readStr } from '../tasks/TaskModels';
import { sharedTaskError, SharedTaskFault } from './SharedTaskModels';
import { SharedAgentNetConfig, SharedAgentNetRoute, SharedAgentNetOrigin, SharingNativeHost, SharingWireCallbacks, SharingWireSocket } from './SharedTaskAgentNet';

export type SharingSecretStore = SecureStore; // Compatibility name: this dependency stores route metadata only.
export interface HarmonySharingNativeOptions { auth: AuthStore; secureStore: SecureStore; scope: () => string; }
function bytes(value: string): Uint8Array {
  return new util.Base64Helper().decodeSync(value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - value.length % 4) % 4));
}
function hash(value: Uint8Array): string {
  const digest = cryptoFramework.createMd('SHA256'); digest.updateSync({ data: value }); return base64Url(digest.digestSync().data);
}
function hashText(value: string): string { return hash(new util.TextEncoder().encodeInto(value)); }
class NativeSharingWire implements SharingWireSocket {
  private wire: webSocket.WebSocket = webSocket.createWebSocket();
  private active: boolean = true;
  private current: () => void;
  constructor(address: string, headers: string, callbacks: SharingWireCallbacks, current: () => void) {
    this.current = current;
    this.wire.on('open', (error: BusinessError): void => { if (!this.active) return; try { current(); if (error) callbacks.error(); else callbacks.open(); } catch { this.close(); } });
    this.wire.on('message', (error: BusinessError, data: string | ArrayBuffer): void => {
      if (!this.active) return;
      try { current(); if (error) callbacks.error(); else callbacks.message(typeof data === 'string' ? data : base64Url(new Uint8Array(data)), typeof data !== 'string'); }
      catch { this.close(); }
    });
    this.wire.on('error', (): void => { if (this.active) callbacks.error(); });
    this.wire.on('close', (_error: BusinessError, result: webSocket.CloseResult): void => { if (this.active) { this.active = false; callbacks.close(result.code); } });
    const options: webSocket.WebSocketRequestOptions = { header: JSON.parse(headers) as Record<string, string> };
    void this.wire.connect(address, options).catch((): void => { if (this.active) callbacks.error(); });
  }
  send(data: string, binary: boolean): void {
    if (!this.active) throw new SharedTaskFault('NOT_CONNECTED'); this.current();
    void this.wire.send(binary ? bytes(data).buffer as ArrayBuffer : data).catch((): void => {});
  }
  close(): void { if (!this.active) return; this.active = false; void this.wire.close().catch((): void => {}); }
}
class NativeHost implements SharingNativeHost {
  didDestroy: () => void = (): void => {};
  message: (text: string) => void = (_text: string): void => {};
  close: (code: number) => void = (_code: number): void => {};
  error: () => void = (): void => {};
  private active: boolean = true;
  private engines: Map<string, AgentNetEngine>;
  private config: SharedAgentNetConfig;
  private options: HarmonySharingNativeOptions;
  private current: () => boolean;
  private epoch: number;
  private wires: Set<SharingWireSocket> = new Set();
  private requests: Map<http.HttpRequest, (reason: Object) => void> = new Map();
  constructor(config: SharedAgentNetConfig, options: HarmonySharingNativeOptions, current: () => boolean, engines: Map<string, AgentNetEngine>) {
    this.config = config; this.options = options; this.current = current; this.engines = engines; this.epoch = options.auth.sessionEpoch;
  }
  check(): void { if (!this.active || !this.current() || !this.options.auth.isLoggedIn || this.epoch !== this.options.auth.sessionEpoch) throw new SharedTaskFault('ACCESS_REVOKED'); }
  command(engine: string, input: string): string {
    this.check(); const target = this.engines.get(engine); if (!target) throw new SharedTaskFault('AGENT_NET_ENGINE_REQUIRED'); return target.command(input);
  }
  sha256(encoded: string): string { this.check(); return hash(bytes(encoded)); }
  async identityCard(nonce: string): Promise<string> {
    this.check(); const token = await this.options.auth.getAccessToken(); this.check();
    if (!token) throw new SharedTaskFault('UNAUTHENTICATED');
    const headers: Record<string, string> = {}; headers['Authorization'] = 'Bearer ' + token;
    const body: Record<string, string> = { 'audience': 'cindy-agent-net-sharing', 'purpose': 'network-session', 'nonce': nonce };
    const response = await new HarmonyHttp().requestJson(AppConfig.authApiBaseUrl + '/api/me/identity-card', 'POST', headers, JSON.stringify(body), 12000, true);
    this.check(); if (response.statusCode < 200 || response.statusCode >= 300) throw new SharedTaskFault('SHARING_IDENTITY_UNAVAILABLE');
    return response.body;
  }
  async memberAuthorization(method: string, path: string, body: string): Promise<string> {
    this.check(); const current = RelayRoute.instance.agentNet;
    if (!this.config.privateMember || !current || current.baseUrl !== this.config.server || current.rootPublicKey !== this.config.rootPublicKey
      || readStr(current.certificate, 'networkId') !== this.config.networkId || readStr(current.certificate, 'subject') !== this.config.subject) throw new SharedTaskFault('AGENT_NET_SHARING_MEMBER_UNAVAILABLE');
    const member = this.engines.get('member'); if (!member) throw new SharedTaskFault('AGENT_NET_SHARING_MEMBER_UNAVAILABLE');
    const random: Record<string, string> = { 'op': 'random' };
    const entropy = readStr(recordOrEmpty(JSON.parse(member.command(JSON.stringify(random))) as Object), 'value');
    const at = Date.now(), nonce = entropy.slice(0, 24);
    if (nonce.length !== 24) throw new SharedTaskFault('INVALID_NATIVE_RANDOM');
    const payload: Object[] = ['cindy-agent-net/request/2', method.toUpperCase(), path, hashText(body), at, nonce];
    const request: Record<string, string> = { 'op': 'sign', 'text': JSON.stringify(payload) };
    const signature = readStr(recordOrEmpty(JSON.parse(member.command(JSON.stringify(request))) as Object), 'value');
    const proof: Record<string, Object> = {}; proof['at'] = at; proof['nonce'] = nonce; proof['signature'] = signature;
    const header: Record<string, Object> = {}; header['certificate'] = current.certificate; header['proof'] = proof;
    this.check(); return 'AgentNet ' + base64Url(new util.TextEncoder().encodeInto(JSON.stringify(header)));
  }
  request(address: string, method: string, headers: string, body: string, binary: boolean): Promise<string> {
    this.check(); this.origin(address, false);
    if (!['GET', 'POST', 'PUT', 'DELETE', 'PATCH'].includes(method)) throw new SharedTaskFault('invalid');
    return new Promise<string>((resolve, reject) => {
      const request = http.createHttp(); this.requests.set(request, reject);
      const options: http.HttpRequestOptions = { method: method as http.RequestMethod, header: JSON.parse(headers) as Record<string, string>,
        expectDataType: http.HttpDataType.ARRAY_BUFFER, usingCache: false, maxRedirects: 0, connectTimeout: 12000, readTimeout: 12000, maxLimit: 32 * 1024 * 1024 };
      if (body) options.extraData = binary ? bytes(body).buffer as ArrayBuffer : body;
      request.request(address, options, (error: BusinessError, response: http.HttpResponse): void => {
        this.requests.delete(request); request.destroy();
        try {
          this.check(); if (error) throw new SharedTaskFault('AGENT_NET_NETWORK_ERROR');
          const responseHeaders: Record<string, string> = {}, original = recordOrEmpty(response.header as Object);
          for (const key of Object.keys(original)) responseHeaders[key] = String(original[key]);
          const data = response.result instanceof ArrayBuffer ? new Uint8Array(response.result) : new util.TextEncoder().encodeInto(String(response.result));
          const value: Record<string, Object> = {}; value['status'] = response.responseCode; value['headers'] = responseHeaders; value['body'] = base64Url(data);
          resolve(JSON.stringify(value));
        } catch (failure) { reject(failure); }
      });
    });
  }
  private origin(address: string, socket: boolean): void {
    const parsed = url.URL.parseURL(address), expected = url.URL.parseURL(this.config.server);
    const protocol = socket ? expected.protocol.replace('http', 'ws') : expected.protocol;
    if (parsed.protocol !== protocol || parsed.host !== expected.host || parsed.username || parsed.password || parsed.hash
      || !parsed.pathname.startsWith(expected.pathname.replace(/\/+$/, '') + '/api/agent-net/')) throw new SharedTaskFault('AGENT_NET_ORIGIN_MISMATCH');
  }
  socket(address: string, headers: string, callbacks: SharingWireCallbacks): SharingWireSocket {
    this.check(); this.origin(address, true);
    const wire = new NativeSharingWire(address, headers, callbacks, (): void => this.check()); this.wires.add(wire); return wire;
  }
  destroyEngine(engine: string): void { this.engines.get(engine)?.close(); this.engines.delete(engine); }
  destroy(): void {
    if (!this.active) return; this.active = false;
    this.engines.forEach((engine: AgentNetEngine): void => engine.close()); this.engines.clear();
    this.wires.forEach((wire: SharingWireSocket): void => wire.close()); this.wires.clear();
    this.requests.forEach((reject: (reason: Object) => void, request: http.HttpRequest): void => { reject(new SharedTaskFault('ACCESS_REVOKED')); request.destroy(); });
    this.requests.clear(); this.didDestroy();
  }
}
export class HarmonySharingNative {
  private options: HarmonySharingNativeOptions;
  private seedStore: SharingSeedStore = new SharingSeedStore();
  private activeHosts: Set<NativeHost> = new Set();
  private stopAuth: (() => void) | null = null;
  private authEpoch: number;
  private privateSharing: boolean = false;
  private infoGeneration: number = -1;
  private infoNext: number = 0;
  constructor(options: HarmonySharingNativeOptions) {
    this.options = options; this.authEpoch = options.auth.sessionEpoch;
    this.stopAuth = options.auth.onChanged((): void => {
      if (!options.auth.isLoggedIn || options.auth.sessionEpoch !== this.authEpoch) { this.closeHosts(); this.authEpoch = options.auth.sessionEpoch; }
    });
  }
  private closeHosts(): void { this.activeHosts.forEach((host: NativeHost): void => host.destroy()); this.activeHosts.clear(); this.seedStore.clearPending(); }
  dispose(): void { this.closeHosts(); this.stopAuth?.(); this.stopAuth = null; }
  randomKeyId(): string { return base64Url(cryptoFramework.createRandom().generateRandomSync(18).data); }
  private assertCurrent(current: () => boolean, epoch: number): void {
    if (!current() || !this.options.auth.isLoggedIn || this.options.auth.sessionEpoch !== epoch) throw new SharedTaskFault('ACCESS_REVOKED');
  }
  private seed(key: string, current: () => boolean, epoch: number): Promise<string> {
    const account = this.options.auth.cacheAccountId;
    return this.seedStore.getOrCreate(AppConfig.region, account, key, (): void => this.assertCurrent(current, epoch));
  }
  async create(config: SharedAgentNetConfig, current: () => boolean): Promise<SharingNativeHost> {
    const epoch = this.options.auth.sessionEpoch, engines: Map<string, AgentNetEngine> = new Map();
    const guard = (): void => this.assertCurrent(current, epoch);
    const account = this.options.auth.cacheAccountId;
    guard(); if (account !== config.accountId) throw new SharedTaskFault('ACCESS_REVOKED');
    const ownerKey = hashText(JSON.stringify([AppConfig.region, account, config.deviceId]));
    try {
      const business = new AgentNetEngineOptions(); business.deviceId = config.deviceId; business.context = 'cindy-agent-net/sharing-business/2'; business.legacySigning = false;
      business.seed = await this.seed('shared-tasks.an.business.v1.' + ownerKey, current, epoch);
      engines.set('business', await AgentNetEngine.create(business, guard)); guard();
      if (config.memberId) {
        if (!config.keyId || !/^[A-Za-z0-9_-]{24}$/.test(config.keyId)) throw new SharedTaskFault('AGENT_NET_SHARING_SEED_UNAVAILABLE');
        const identityRequest: Record<string, string> = { 'op': 'identity' };
        const identity = recordOrEmpty(recordOrEmpty(JSON.parse(engines.get('business')!.command(JSON.stringify(identityRequest))) as Object)['value']);
        const applicant = new AgentNetEngineOptions(); applicant.legacySigning = false;
        applicant.deviceId = config.v === 3 ? 'guest:' + readStr(identity, 'signingKey') : config.deviceId;
        applicant.context = JSON.stringify(['cindy-agent-net/sharing-transport/2', config.rootPublicKey, 'shared-task', config.resourceId]);
        applicant.seed = await this.seed('shared-tasks.an.transport.v1.' + ownerKey + '.' + hashText(JSON.stringify([config.server, config.networkId, config.rootPublicKey, config.resourceId, config.keyId])), current, epoch);
        engines.set('applicant', await AgentNetEngine.create(applicant, guard)); guard();
        const transport = new AgentNetEngineOptions(); transport.deviceId = applicant.deviceId; transport.context = applicant.context; transport.seed = applicant.seed;
        transport.legacySigning = false; transport.udp = true; transport.enhancedTransport = true; engines.set('transport', await AgentNetEngine.create(transport, guard)); guard();
      }
      if (config.privateMember) {
        const route = RelayRoute.instance.agentNet;
        if (!route || route.baseUrl !== config.server || route.rootPublicKey !== config.rootPublicKey || readStr(route.certificate, 'networkId') !== config.networkId) throw new SharedTaskFault('AGENT_NET_SHARING_MEMBER_UNAVAILABLE');
        const member = new AgentNetEngineOptions(); member.seed = route.seed; member.context = route.relayId; member.deviceId = route.deviceId;
        engines.set('member', await AgentNetEngine.create(member, guard)); guard();
      }
      const native = new NativeHost(config, this.options, current, engines);
      this.activeHosts.add(native); native.didDestroy = (): void => { this.activeHosts.delete(native); }; return native;
    } catch (error) { engines.forEach((engine: AgentNetEngine): void => engine.close()); throw sharedTaskError(error); }
  }
  accountOrigins(): SharedAgentNetOrigin[] {
    const route = RelayRoute.instance.agentNet;
    if (!route || !this.options.auth.isLoggedIn || route.accountId !== this.options.auth.cacheAccountId) return [];
    const networkId = readStr(route.certificate, 'networkId');
    const basic: SharedAgentNetOrigin = { v: 2, server: route.baseUrl, networkId, rootPublicKey: route.rootPublicKey,
      region: AppConfig.region, privateMember: false, subject: this.options.auth.cacheAccountId };
    const values: SharedAgentNetOrigin[] = [basic];
    if (this.privateSharing && this.infoGeneration === RelayRoute.instance.generation && networkId.startsWith('private:')) {
      const privateOrigin: SharedAgentNetOrigin = { v: 3, server: route.baseUrl, networkId, rootPublicKey: route.rootPublicKey,
        region: AppConfig.region, privateMember: true, subject: readStr(route.certificate, 'subject') };
      values.push(privateOrigin);
    }
    return values;
  }
  accountOrigin(): SharedAgentNetOrigin | null { const origins = this.accountOrigins(); return origins.length ? origins[origins.length - 1] : null; }
  private async probeInfo(scope: string): Promise<void> {
    const route = RelayRoute.instance.agentNet, generation = RelayRoute.instance.generation;
    if (!route || scope !== this.options.scope()) return;
    if (generation !== this.infoGeneration) { this.infoGeneration = generation; this.infoNext = 0; this.privateSharing = false; }
    if (Date.now() < this.infoNext) return;
    this.infoNext = Date.now() + 60000;
    try {
      const headers: Record<string, string> = {};
      const response = await new HarmonyHttp().requestJson(route.baseUrl + '/api/agent-net/info', 'GET', headers, undefined, 5000, true);
      if (scope !== this.options.scope() || generation !== RelayRoute.instance.generation) return;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        const features = recordOrEmpty(JSON.parse(response.body) as Object)['features'];
        this.privateSharing = Array.isArray(features) && (features as Object[]).includes('private-sharing-v1'); this.infoNext = Date.now() + 600000;
      }
    } catch { /* Existing pinned invitation roots work independently of this optional own-network discovery. */ }
  }
  async loadRoutes(scope: string): Promise<SharedAgentNetRoute[]> {
    if (scope !== this.options.scope()) throw new SharedTaskFault('ACCESS_REVOKED');
    await this.probeInfo(scope);
    const key = 'shared-tasks.an.routes.v1.' + hashText(JSON.stringify([AppConfig.region, this.options.auth.cacheAccountId]));
    const raw = await this.options.secureStore.get(key, '[]');
    if (scope !== this.options.scope()) throw new SharedTaskFault('ACCESS_REVOKED');
    const parsed = JSON.parse(raw) as Object;
    if (!Array.isArray(parsed)) throw new SharedTaskFault('invalid'); return parsed as SharedAgentNetRoute[];
  }
  async saveRoutes(scope: string, routes: SharedAgentNetRoute[]): Promise<void> {
    if (scope !== this.options.scope()) throw new SharedTaskFault('ACCESS_REVOKED');
    const key = 'shared-tasks.an.routes.v1.' + hashText(JSON.stringify([AppConfig.region, this.options.auth.cacheAccountId]));
    await this.options.secureStore.set(key, JSON.stringify(routes));
    if (scope !== this.options.scope()) throw new SharedTaskFault('ACCESS_REVOKED');
  }
}

export function sharingParseUrl(value: string): string {
  const parsed = url.URL.parseURL(value);
  const properties: Record<string, string> = { 'protocol': parsed.protocol, 'hostname': parsed.hostname, 'host': parsed.host,
    'username': parsed.username, 'password': parsed.password, 'search': parsed.search, 'hash': parsed.hash,
    'pathname': parsed.pathname, 'href': parsed.href, 'port': parsed.port, 'origin': parsed.protocol + '//' + parsed.host };
  return JSON.stringify(properties);
}
export function sharingQueryPairs(value: string): string {
  const pairs: string[][] = [];
  for (const part of value.replace(/^\?/, '').split('&')) {
    if (!part) continue;
    const equal = part.indexOf('=');
    const key = decodeURIComponent((equal < 0 ? part : part.slice(0, equal)).replace(/\+/g, ' '));
    const text = decodeURIComponent((equal < 0 ? '' : part.slice(equal + 1)).replace(/\+/g, ' '));
    const pair: string[] = [key, text]; pairs.push(pair);
  }
  return JSON.stringify(pairs);
}
