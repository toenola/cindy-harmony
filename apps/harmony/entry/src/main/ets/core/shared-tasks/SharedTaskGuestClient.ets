import { WsAdapter } from '../../network/WsAdapter';
import { DlClient, DlClientOptions, DlEvents, DlInvokeOptions, DlOpenLinkOptions, ScopedPeerPort, assertInvokeSucceeded } from '../device-link/DlClient';
import { Envelope, HelloPayload, CONTROLLER_CAPABILITIES, DlError } from '../device-link/DlProtocol';
import { recordOrEmpty, readStr } from '../tasks/TaskModels';
import { sharedTaskError, SharedTaskDetail, SharedTaskGuestTransport, SharedTaskSessionTarget, sharedTaskHostPeerKey, SharedTaskFault } from './SharedTaskModels';
import { SharedTaskScopeCodec, SharedTaskSocketIdentity, SHARED_TASK_SCOPE_CAPABILITY } from './SharedTaskScope';
import { SharedTaskSocket } from './SharedTaskSocket';

export interface SharedTaskRoutingPort {
  invokeEnvelope: (channel: string, args: Object[], timeoutMs?: number, preSend?: () => void) => Promise<Envelope>;
  subscribeTopics: (topics: string[]) => Promise<Envelope>;
  unsubscribeTopics: (topics: string[]) => Promise<Envelope>;
  getStatus: () => string;
  connectionIdentity: () => string;
  onStatus: (listener: (status: string) => void) => () => void;
}
export interface SharedTaskAgentNetMedia {
  upload: (size: number, contentType: string, read: (offset: number, length: number) => Promise<string>) => Promise<string>;
  download: (key: string, write: (base64url: string, offset: number) => Promise<void>) => Promise<string>;
  delete?: (key: string) => Promise<void>;
}
export interface SharedTaskReadyTransport extends SharedTaskGuestTransport { routing: SharedTaskRoutingPort; session: Object; agentNetMedia?: SharedTaskAgentNetMedia;
  scopedPort: () => ScopedPeerPort; onClosed: (listener: () => void) => () => void; }
export interface SharedTaskMediaPorts {
  upload: (target: SharedTaskSessionTarget, localUri: string, name: string, mime: string) => Promise<string>;
  fetch: (target: SharedTaskSessionTarget, reference: string) => Promise<Object | undefined>;
  delete?: (target: SharedTaskSessionTarget, key: string) => Promise<void>;
}
export interface SharedTaskGuestClientPorts {
  accountId: string;
  // Fixed official websocket endpoint, or a pinned AN sharing route's synthetic URL. No control-relay fallback.
  wsUrl: string;
  getToken: () => Promise<string | null>;
  getHello: () => HelloPayload;
  createWs: () => WsAdapter;
  current: () => boolean;
  refreshAuth: () => void;
  media: SharedTaskMediaPorts;
  transport: string;
}
/** Dedicated DlClient; only this task is encoded at this socket, never the owner client's frames. */
export class SharedTaskGuestClient implements SharedTaskReadyTransport, SharedTaskRoutingPort {
  target: SharedTaskSessionTarget;
  session: Object = new Object();
  routing: SharedTaskRoutingPort = this;
  agentNetMedia: SharedTaskAgentNetMedia | undefined = undefined;
  private client: DlClient;
  private ports: SharedTaskGuestClientPorts;
  private closed: boolean = false;
  private epoch: number = 0;
  private linkedEpoch: number = -1;
  private preparing: Promise<void> | null = null;
  private listeners: Array<(channel: string, payload: Object) => void> = [];
  private revocations: Array<() => void> = [];
  private closures: Array<() => void> = [];
  private statuses: Array<(status: string) => void> = [];
  private failOpening: (error: Error) => void = (_error: Error): void => {};
  constructor(detail: SharedTaskDetail, memberId: string, ports: SharedTaskGuestClientPorts) {
    this.ports = ports;
    this.target = { sharedTaskId: detail.sharedTaskId, sessionId: detail.sessionId, ownerAccountId: detail.ownerAccountId,
      hostDeviceId: detail.hostDeviceId, title: detail.title, peer: sharedTaskHostPeerKey(detail.sharedTaskId, detail.hostDeviceId),
      guest: true, transport: ports.transport };
    const identity: SharedTaskSocketIdentity = { sharedTaskId: detail.sharedTaskId, hostDeviceId: detail.hostDeviceId, memberId };
    const options = new DlClientOptions(), events = new DlEvents();
    options.getWsUrl = (): string => ports.wsUrl;
    options.getToken = async (): Promise<string | null> => { this.assertCurrent(); return ports.getToken(); };
    options.getHello = ports.getHello;
    options.createWs = (): WsAdapter => new SharedTaskSocket(ports.createWs(), new SharedTaskScopeCodec(identity, ports.accountId, true),
      (): boolean => !this.closed && ports.current(), (error: Error): void => { this.failOpening(error); });
    events.onStatus = (status: string): void => {
      this.epoch++; this.linkedEpoch = -1;
      this.statuses.forEach((listener: (status: string) => void): void => listener(status));
      if (status === 'online' && !this.closed) void this.prepare().catch((error: Object): void => this.failOpening(error instanceof Error ? error : new Error('SHARED_TASK_OPEN_FAILED')));
    };
    events.onAuthFailed = ports.refreshAuth;
    events.onPush = (peer: string, channel: string, payload: Object | undefined): void => {
      if (peer !== this.target.hostDeviceId || !payload || !this.isCurrent()) return;
      this.listeners.forEach((listener: (channel: string, payload: Object) => void): void => listener(channel, payload));
    };
    events.onLinkClosed = (peer: string, reason: string): void => {
      if (peer !== this.target.hostDeviceId) return;
      this.linkedEpoch = -1;
      if (/^(ACCESS_REVOKED|access-revoked|shared-task-closed|shared-task-revoked|revoked|closed)$/.test(reason)) this.revoke();
    };
    options.events = events; this.client = new DlClient(options);
  }
  private isCurrent(): boolean { return !this.closed && this.ports.current(); }
  private assertCurrent(): void { if (!this.isCurrent()) throw new SharedTaskFault('ACCESS_REVOKED'); }
  scopedPort(): ScopedPeerPort { return new ActualScopedPeerPort(this); }
  current(): boolean { return this.isCurrent(); }
  historyView(): boolean { return this.client.supportsHistoryView(this.target.hostDeviceId); }
  onClosed(listener: () => void): () => void { this.closures.push(listener); return (): void => { this.closures = this.closures.filter((entry: () => void): boolean => entry !== listener); }; }
  getStatus(): string { return this.closed ? 'stopped' : this.linkedEpoch === this.epoch ? this.client.getStatus() : 'connecting'; }
  connectionIdentity(): string { return this.target.peer + ':' + this.epoch + ':' + this.linkedEpoch; }
  onStatus(listener: (status: string) => void): () => void {
    this.statuses.push(listener);
    return (): void => { this.statuses = this.statuses.filter((item: (status: string) => void): boolean => item !== listener); };
  }
  async open(): Promise<void> {
    this.assertCurrent();
    let timer: number = -1;
    try {
      await new Promise<void>((resolve, reject) => {
        this.failOpening = (error: Error): void => reject(error);
        const off = this.onStatus((status: string): void => {
          if (status === 'ready') { off(); resolve(); }
        });
        timer = setTimeout((): void => { off(); reject(new DlError('NOT_CONNECTED', 'Shared task handshake timeout')); }, 30000);
        this.client.start();
      });
      this.assertCurrent();
    } catch (error) { this.close(); throw sharedTaskError(error); }
    finally { if (timer >= 0) clearTimeout(timer); }
  }
  private async prepare(): Promise<void> {
    if (this.preparing) return this.preparing;
    const epoch = this.epoch;
    const work = this.prepareNow(epoch).finally((): void => { if (this.preparing === work) this.preparing = null; });
    this.preparing = work;
    void work.finally((): void => { if (!this.closed && epoch !== this.epoch && this.client.getStatus() === 'online') void this.prepare().catch((): void => {}); }).catch((): void => {});
    return work;
  }
  private async prepareNow(epoch: number): Promise<void> {
    this.assertCurrent();
    const options = new DlOpenLinkOptions();
    options.controllerName = this.ports.getHello().deviceName; options.appVersion = this.ports.getHello().appVersion;
    options.capabilities = CONTROLLER_CAPABILITIES.concat([SHARED_TASK_SCOPE_CAPABILITY]);
    const accepted = await this.client.openLink(this.target.hostDeviceId, options);
    this.assertCurrent();
    const capabilities = recordOrEmpty(accepted.payload)['capabilities'];
    if (!Array.isArray(capabilities) || !(capabilities as Object[]).includes(SHARED_TASK_SCOPE_CAPABILITY)) throw new SharedTaskFault('VERSION_MISMATCH');
    const subscribed = await this.client.subscribe(this.target.hostDeviceId, ['session:' + this.target.sessionId]);
    assertInvokeSucceeded(subscribed); this.assertCurrent();
    const request = new DlInvokeOptions(); request.channel = 'local-db:sessions:get'; request.args = [this.target.sessionId];
    const snapshot = unwrapSharedTaskResult(await this.client.invoke(this.target.hostDeviceId, request));
    this.assertCurrent();
    if (!snapshot || readStr(recordOrEmpty(snapshot), 'id') !== this.target.sessionId) throw new SharedTaskFault('invalid');
    if (epoch !== this.epoch) throw new SharedTaskFault('NOT_CONNECTED');
    this.session = snapshot; this.linkedEpoch = epoch;
    this.statuses.forEach((listener: (status: string) => void): void => listener('ready'));
  }
  async invokeEnvelope(channel: string, args: Object[], timeoutMs?: number, preSend?: () => void): Promise<Envelope> {
    this.assertCurrent(); if (this.linkedEpoch !== this.epoch) await this.prepare(); this.assertCurrent();
    const options = new DlInvokeOptions(); options.channel = channel; options.args = args; options.timeoutMs = timeoutMs;
    options.preSend = (): void => { this.assertCurrent(); preSend?.(); };
    const value = await this.client.invoke(this.target.hostDeviceId, options); this.assertCurrent(); return value;
  }
  async invoke(channel: string, args: Object[]): Promise<Object | undefined> { return unwrapSharedTaskResult(await this.invokeEnvelope(channel, args)); }
  private topics(topics: string[]): string[] {
    if (topics.length !== 1 || topics[0] !== 'session:' + this.target.sessionId) throw new SharedTaskFault('forbidden');
    return topics;
  }
  async subscribeTopics(topics: string[]): Promise<Envelope> {
    this.assertCurrent(); const result = await this.client.subscribe(this.target.hostDeviceId, this.topics(topics));
    assertInvokeSucceeded(result); this.assertCurrent(); return result;
  }
  async unsubscribeTopics(topics: string[]): Promise<Envelope> {
    this.assertCurrent(); const result = await this.client.unsubscribe(this.target.hostDeviceId, this.topics(topics));
    assertInvokeSucceeded(result); this.assertCurrent(); return result;
  }
  subscribe(listener: (channel: string, payload: Object) => void): () => void {
    this.assertCurrent(); this.listeners.push(listener);
    return (): void => { this.listeners = this.listeners.filter((item: (channel: string, payload: Object) => void): boolean => item !== listener); };
  }
  async upload(localUri: string, name: string, mime: string): Promise<string> {
    this.assertCurrent(); const ref = await this.ports.media.upload(this.target, localUri, name, mime); this.assertCurrent(); return ref;
  }
  async fetch(reference: string): Promise<Object | undefined> {
    this.assertCurrent(); const result = await this.ports.media.fetch(this.target, reference); this.assertCurrent(); return result;
  }
  async delete(key: string): Promise<void> {
    this.assertCurrent();
    if (!this.ports.media.delete) throw new SharedTaskFault('unsupported');
    await this.ports.media.delete(this.target, key); this.assertCurrent();
  }
  onRevoked(listener: () => void): () => void {
    this.revocations.push(listener);
    return (): void => { this.revocations = this.revocations.filter((item: () => void): boolean => item !== listener); };
  }
  private revoke(): void { if (this.closed) return; const listeners = this.revocations.slice(); this.close(); listeners.forEach((listener: () => void): void => listener()); }
  close(): void { if (this.closed) return; this.closed = true; this.epoch++; this.client.stop(); this.listeners = []; this.revocations = []; this.statuses = [];
    const closures = this.closures.slice(); this.closures = []; closures.forEach((listener: () => void): void => listener()); }
}
export function unwrapSharedTaskResult(env: Envelope): Object | undefined {
  assertInvokeSucceeded(env); return recordOrEmpty(env.payload)['result'];
}
export async function createSharedTaskGuestClient(detail: SharedTaskDetail, memberId: string, ports: SharedTaskGuestClientPorts): Promise<SharedTaskReadyTransport> {
  const client = new SharedTaskGuestClient(detail, memberId, ports); await client.open(); return client;
}

class ActualScopedPeerPort implements ScopedPeerPort {
  private guest: SharedTaskGuestClient;
  constructor(guest: SharedTaskGuestClient) { this.guest = guest; }
  current(): boolean { return this.guest.current(); }
  identity(): string { return this.guest.connectionIdentity(); }
  status(): string { return this.guest.getStatus(); }
  async invoke(channel: string, args: Object[], timeoutMs: number, preSend?: () => void): Promise<Object | undefined> { return unwrapSharedTaskResult(await this.guest.invokeEnvelope(channel, args, timeoutMs, preSend)); }
  async subscribe(topics: string[]): Promise<void> { await this.guest.subscribeTopics(topics); }
  async unsubscribe(topics: string[]): Promise<void> { await this.guest.unsubscribeTopics(topics); }
  close(): void { this.guest.close(); }
  supportsHistoryView(): boolean { return this.guest.historyView(); }
}
