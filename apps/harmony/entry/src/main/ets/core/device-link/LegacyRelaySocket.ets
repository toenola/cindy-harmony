import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { HarmonyWsAdapter } from '../../network/HarmonyWsAdapter';
import { WsAdapter, WsCallbacks, WsMessage } from '../../network/WsAdapter';
import { HarmonyHttp } from '../../network/HarmonyHttp';
import { AgentNetEngine, AgentNetEngineOptions } from './AgentNetEngine';
import { LegacyRelayMembership } from './LegacyRelayPairing';
import { base64Url, engineCall } from './AgentNetPairing';
import { readStr, readObj, readNum, recordOrEmpty } from '../tasks/TaskModels';

const ROUTED = ['link-open', 'link-accept', 'link-close', 'invoke', 'invoke-result', 'push'];
const AUTH_CHANNEL = 'device-link:relay-auth';
const KEY = /^[A-Za-z0-9_-]{43}$/;
const BOOT = /^[A-Za-z0-9_-]{16,32}$/;
const SIGNATURE = /^[A-Za-z0-9_-]{86}$/;
const SKEW_MS = 600000;

class PeerBoot {
  boot: string = '';
  ready: boolean = false;
}
class ReplayCounter {
  count: number = 0;
  at: number = 0;
}

class RelaySocketMessage implements WsMessage {
  private text: string;
  constructor(text: string) { this.text = text; }
  toString(): string { return this.text; }
}

export class LegacyRelaySocket implements WsAdapter {
  private socket: HarmonyWsAdapter = new HarmonyWsAdapter();
  private callbacks: WsCallbacks = new WsCallbacks();
  private engine: AgentNetEngine | undefined;
  private boot: string = base64Url(cryptoFramework.createRandom().generateRandomSync(12).data);
  private count: number = 0;
  private active: boolean = true;
  private peers: Map<string, PeerBoot> = new Map();
  private signers: Map<string, string> = new Map();
  private replay: Map<string, ReplayCounter> = new Map();
  private queued: Map<string, string[]> = new Map();
  private lastCertificatesAt: number = 0;
  private certificatesPending: Promise<void> | undefined;
  private handshakeTimers: Map<string, number> = new Map();

  private membership: LegacyRelayMembership;
  private assertCurrent: () => void;

  constructor(membership: LegacyRelayMembership, assertCurrent: () => void) {
    this.membership = membership;
    this.assertCurrent = assertCurrent;
  }

  setCallbacks(callbacks: WsCallbacks): void {
    this.callbacks = callbacks;
  }

  connect(_url: string, _headers: Record<string, string>): void {
    void this.open().catch(() => {
      if (this.active) {
        this.dispose();
        this.callbacks.onError(new Error('RELAY_AUTHENTICATION_UNAVAILABLE'));
      }
    });
  }

  private guard(): void {
    this.assertCurrent();
    if (!this.active) throw new Error('RELAY_CONNECTION_CLOSED');
  }

  private async open(): Promise<void> {
    this.guard();
    const options = new AgentNetEngineOptions();
    options.seed = this.membership.seed;
    options.context = this.membership.relayId;
    options.deviceId = this.membership.deviceId;
    const engine = await AgentNetEngine.create(options, () => this.guard());
    this.engine = engine;
    await this.refreshCertificates();
    this.guard();
    const callbacks = new WsCallbacks();
    callbacks.onOpen = () => this.callbacks.onOpen();
    callbacks.onMessage = (message) => {
      try {
        this.guard();
        const frame = recordOrEmpty(JSON.parse(message.toString()) as Object);
        if (!ROUTED.includes(readStr(frame, 'kind'))) {
          this.callbacks.onMessage(message);
        } else if (this.verify(frame)) {
          this.deliver(frame, message.toString());
        }
      } catch (_error) {
        hilog.warn(0, 'CindyRelay', 'frame verification failed code=%{public}s', String((_error as Record<string, Object>)['code']));
        // Unverified frames never reach the conversation or its interaction cards.
      }
    };
    callbacks.onClose = (code: number, reason: string) => {
      this.dispose();
      this.callbacks.onClose(code, reason);
    };
    callbacks.onError = (error: Error) => this.callbacks.onError(error);
    this.socket.setCallbacks(callbacks);
    const headers: Record<string, string> = { 'Authorization': 'CindyRelay ' + this.membership.credential };
    this.socket.connect(this.membership.baseUrl.replace(/^http/, 'ws') + '/api/device-link/ws', headers);
  }

  private async refreshCertificates(): Promise<void> {
    if (this.certificatesPending) return this.certificatesPending;
    const operation = this.readCertificates();
    this.certificatesPending = operation;
    try {
      await operation;
    } finally {
      if (this.certificatesPending === operation) this.certificatesPending = undefined;
    }
  }

  private async readCertificates(): Promise<void> {
    this.guard();
    this.lastCertificatesAt = Date.now();
    const response = await new HarmonyHttp().requestJson(
      this.membership.baseUrl + '/api/device-link/relay/certs', 'GET',
      { 'Authorization': 'CindyRelay ' + this.membership.credential }, undefined, 10000, true);
    this.guard();
    if (response.statusCode !== 200) throw new Error('RELAY_CERTIFICATES_UNAVAILABLE');
    const parsed = recordOrEmpty(JSON.parse(response.body) as Object);
    const certs = parsed['certs'];
    if (!Array.isArray(certs) || certs.length > 1000) throw new Error('RELAY_CERTIFICATES_INVALID');
    const next = new Map<string, string>();
    for (const raw of certs as Object[]) {
      const cert = recordOrEmpty(raw as Object);
      const device = readStr(cert, 'deviceId');
      const key = readStr(cert, 'publicKey');
      const role = readStr(cert, 'role');
      const issuedAt = readNum(cert, 'issuedAt', -1);
      if (cert['v'] !== 1 || cert['relayId'] !== this.membership.relayId || !device || device.length > 256
        || !KEY.test(key) || !['owner', 'member'].includes(role) || !Number.isSafeInteger(issuedAt)) continue;
      if (this.verifySignature(this.membership.ownerPublicKey,
        JSON.stringify(['cindy-relay-cert/1', this.membership.relayId, device, key, role, issuedAt]),
        readStr(cert, 'signature'))) next.set(device, key);
    }
    this.signers.forEach((key: string, device: string) => {
      if (next.get(device) !== key) this.peers.delete(device);
    });
    this.signers = next;
    hilog.info(0, 'CindyRelay', 'verified signer count=%{public}d', next.size);
  }

  private verifySignature(key: string, text: string, signature: string): boolean {
    if (!this.engine || !KEY.test(key) || !SIGNATURE.test(signature)) return false;
    return engineCall(this.engine, { 'op': 'verify', 'key': key, 'text': text, 'signature': signature }) === true;
  }

  private handshake(frame: Record<string, Object>): string {
    const payload = readObj(frame, 'payload');
    const body = readObj(payload, 'payload');
    const type = readStr(body, 'type');
    return frame['kind'] === 'push' && readStr(frame, 'id').length > 0
      && payload['channel'] === AUTH_CHANNEL && Object.keys(payload).length === 2
      && Object.keys(body).length === 1 && ['request', 'response'].includes(type) ? type : '';
  }

  private digest(frame: Record<string, Object>, src: string, at: number, boot: string, receiver: string,
    count: number): string {
    const header: Array<Object | null> = ['cindy-relay-frame/2', this.membership.relayId, src, readStr(frame, 'dst'),
      readStr(frame, 'kind'), frame['id'] === undefined ? null : frame['id'], at, boot, receiver, count];
    const body = frame['payload'] === undefined ? '' : JSON.stringify(frame['payload']);
    const md = cryptoFramework.createMd('SHA256');
    md.updateSync({ data: new util.TextEncoder().encodeInto(JSON.stringify(header) + '\n' + body) });
    return base64Url(md.digestSync().data);
  }

  private bytes(value: string): Uint8Array {
    return new util.Base64Helper().decodeSync(value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - value.length % 4) % 4));
  }

  private rawSignature(key: string, digest: string, signature: string): boolean {
    const raw = this.bytes(key);
    const prefix = new Uint8Array([48, 42, 48, 5, 6, 3, 43, 101, 112, 3, 33, 0]);
    const der = new Uint8Array(prefix.length + raw.length);
    der.set(prefix);
    der.set(raw, prefix.length);
    const pair = cryptoFramework.createAsyKeyGenerator('Ed25519').convertKeySync({ data: der }, null);
    const verifier = cryptoFramework.createVerify('Ed25519');
    verifier.initSync(pair.pubKey);
    return verifier.verifySync({ data: this.bytes(digest) }, { data: this.bytes(signature) });
  }

  private signRaw(digest: string): string {
    const prefix = new Uint8Array([48, 46, 2, 1, 0, 48, 5, 6, 3, 43, 101, 112, 4, 34, 4, 32]);
    const der = new Uint8Array(48);
    der.set(prefix);
    der.set(this.bytes(this.membership.seed), prefix.length);
    const pair = cryptoFramework.createAsyKeyGenerator('Ed25519').convertKeySync(null, { data: der });
    const signer = cryptoFramework.createSign('Ed25519');
    signer.initSync(pair.priKey);
    return base64Url(signer.signSync({ data: this.bytes(digest) }).data);
  }

  private verify(frame: Record<string, Object>): boolean {
    if (frame['sharedTask'] !== undefined || frame['providerShare'] !== undefined
      || frame['dst'] !== this.membership.deviceId) return false;
    const src = readStr(frame, 'src');
    const key = this.signers.get(src);
    if (!key) {
      hilog.warn(0, 'CindyRelay', 'frame signer unavailable');
      if (Date.now() - this.lastCertificatesAt >= 5000) void this.refreshCertificates().catch(() => {});
      return false;
    }
    const auth = readObj(frame, 'auth');
    const at = readNum(auth, 't', -1);
    const count = readNum(auth, 'c', -1);
    const boot = readStr(auth, 'b');
    const receiver = readStr(auth, 'r');
    if (!Number.isSafeInteger(at) || !Number.isSafeInteger(count) || count < 1
      || !BOOT.test(boot) || (receiver !== '' && !BOOT.test(receiver)) || Math.abs(Date.now() - at) > SKEW_MS) return false;
    const replayKey = JSON.stringify([src, boot]);
    if ((this.replay.get(replayKey)?.count ?? 0) >= count) return false;
    if (!this.engine) return false;
    if (!this.rawSignature(key, this.digest(frame, src, at, boot, receiver, count), readStr(auth, 's'))) {
      hilog.warn(0, 'CindyRelay', 'frame signature invalid');
      if (Date.now() - this.lastCertificatesAt >= 5000) void this.refreshCertificates().catch(() => {});
      return false;
    }
    const type = this.handshake(frame);
    if (type !== 'request' && receiver !== this.boot) {
      this.peers.delete(src);
      return false;
    }
    if (!this.replay.has(replayKey) && this.replay.size >= 1000) {
      this.replay.forEach((entry: ReplayCounter, key: string) => {
        if (Date.now() - entry.at > 2 * SKEW_MS) this.replay.delete(key);
      });
      if (this.replay.size >= 1000) return false;
    }
    const previous = this.peers.get(src);
    const peer = new PeerBoot();
    peer.boot = boot;
    peer.ready = type !== 'request' || (previous?.boot === boot && previous.ready);
    this.peers.set(src, peer);
    const counter = new ReplayCounter();
    counter.count = count;
    counter.at = Math.max(at, this.replay.get(replayKey)?.at ?? 0);
    this.replay.set(replayKey, counter);
    if (this.replay.size > 1000) {
      this.replay.forEach((entry: ReplayCounter, key: string) => {
        if (Date.now() - entry.at > 2 * SKEW_MS) this.replay.delete(key);
      });
    }
    if (Date.now() - this.lastCertificatesAt >= SKEW_MS) void this.refreshCertificates().catch(() => {});
    return true;
  }

  private deliver(frame: Record<string, Object>, text: string): void {
    const type = this.handshake(frame);
    const src = readStr(frame, 'src');
    if (type === 'request') this.sendChallenge(src, 'response');
    else if (type === 'response') {
      const timer = this.handshakeTimers.get(src);
      if (timer !== undefined) clearTimeout(timer);
      this.handshakeTimers.delete(src);
      const queue = this.queued.get(src) ?? [];
      this.queued.delete(src);
      for (const pending of queue) this.send(pending);
    } else {
      this.callbacks.onMessage(new RelaySocketMessage(text));
    }
  }

  private sendChallenge(dst: string, type: string): void {
    const body: Record<string, Object> = { 'type': type };
    const payload: Record<string, Object> = { 'channel': AUTH_CHANNEL, 'payload': body };
    const frame: Record<string, Object> = { 'v': 1, 'kind': 'push', 'id': util.generateRandomUUID(), 'dst': dst, 'payload': payload };
    this.send(JSON.stringify(frame));
  }

  send(data: string): boolean {
    try {
      this.guard();
      const frame = recordOrEmpty(JSON.parse(data) as Object);
      if (!ROUTED.includes(readStr(frame, 'kind'))) return this.socket.send(data);
      const dst = readStr(frame, 'dst');
      const type = this.handshake(frame);
      if (!type && this.peers.get(dst)?.ready !== true) {
        const queue = this.queued.get(dst) ?? [];
        if (queue.length >= 128 || this.queued.size >= 32) return false;
        queue.push(data);
        this.queued.set(dst, queue);
        if (!this.handshakeTimers.has(dst)) {
          this.sendChallenge(dst, 'request');
          this.handshakeTimers.set(dst, setTimeout(() => {
            const failed = this.queued.get(dst) ?? [];
            this.queued.delete(dst);
            this.handshakeTimers.delete(dst);
            // A peer timeout is not a failure of the shared relay WebSocket.
            // Complete only that peer's queued requests through the existing request error path.
            for (const text of failed) {
              const pending = recordOrEmpty(JSON.parse(text) as Object);
              const id = readStr(pending, 'id');
              if (!id) continue;
              const payload: Record<string, Object> = { 'code': 'RELAY_PEER_AUTH_TIMEOUT', 'message': 'peer authentication timed out' };
              const reply: Record<string, Object> = { 'v': 1, 'kind': 'relay-error', 'id': id, 'payload': payload };
              this.callbacks.onMessage(new RelaySocketMessage(JSON.stringify(reply)));
            }
          }, 10000));
        }
        return true;
      }
      const at = Date.now();
      const count = ++this.count;
      const receiver = type === 'request' ? '' : this.peers.get(dst)?.boot ?? '';
      const hash = this.digest(frame, this.membership.deviceId, at, this.boot, receiver, count);
      const signature = this.signRaw(hash);
      const auth: Record<string, Object> = { 't': at, 'b': this.boot, 'r': receiver, 'c': count, 's': signature };
      frame['auth'] = auth;
      return this.socket.send(JSON.stringify(frame));
    } catch (_error) {
      const message = _error instanceof Error ? _error.name : 'Error';
      const code = (_error as Record<string, Object>)['code'];
      hilog.warn(0, 'CindyRelay', 'frame signing failed code=%{public}s detail=%{public}s', String(code),
        message.replace(/[A-Za-z0-9_-]{40,}/g, '[redacted]').slice(0, 180));
      return false;
    }
  }

  close(code: number = 1000, reason: string = ''): void {
    this.dispose();
    this.socket.close(code, reason);
  }

  terminate(): void {
    this.dispose();
    this.socket.terminate();
  }

  private dispose(): void {
    this.active = false;
    this.engine?.close();
    this.engine = undefined;
    this.handshakeTimers.forEach((timer: number) => clearTimeout(timer));
    this.handshakeTimers.clear();
    this.queued.clear();
    this.peers.clear();
    this.signers.clear();
    this.replay.clear();
  }
}
