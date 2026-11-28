// Entry bundled from the fixed 91179cedad package snapshot by build.mjs. Never executes repo JS in a WebView.
import { AgentNetSharingClient } from '../../../../../../../../../packages/agent-net/src/sharingClient.ts';
import { AgentNetSharingTransport } from '../../../../../../../../../packages/agent-net/src/sharingTransport.ts';
import { parseAgentNetSharingInvitation, buildAgentNetSharingInvitation } from '../../../../../../../../../packages/agent-net/src/sharingInvitation.ts';
import { PortableAgentNetClient } from '../../../../../../../../../packages/agent-net/src/portableClient.ts';
import { AgentNetSocket } from '../../../../../../../../../packages/agent-net/src/portableSocket.ts';
import { NativeTransport } from '../../../../../../../../../packages/agent-net/src/nativeTransport.ts';
import { uploadNativeMedia, readNativeMedia } from '../../../../../../../../../packages/agent-net/src/nativeMedia.ts';
import { sharedTaskHostPeer } from '../../../../../../../../../packages/device-link/src/sharedTaskPeer.ts';
import { buildAgentNetMediaKey, parseAgentNetMediaKey, agentNetMediaBinding } from '../../../../../../../../../packages/agent-net-protocol/src/index.ts';
import { fromBase64Url, toBase64Url } from '../../../../../../../../../packages/agent-net/src/portableBytes.ts';
import { certificatePayload, certificatePolicyValid, delegationPayload, delegationPolicyValid, agentNetSharingSubject }
  from '../../../../../../../../../packages/agent-net-protocol/src/index.ts';
import '../../../../../../../native/portable/polyfill.ts';

export function parseSharingInvitation(input) {
  const parsed = parseAgentNetSharingInvitation(input, 'shared-task');
  return parsed ? JSON.stringify(parsed) : '';
}
export function buildSharingInvitation(receipt, server, app) {
  return buildAgentNetSharingInvitation(JSON.parse(receipt), server, app || 'cindy');
}
/** The same parsed receipt/source selection as Mobile deleteMobileAgentNetMedia; no owner fallback. */
export async function deleteScopedAgentNetMedia(key, scopeText, assertCurrent, remove) {
  assertCurrent();
  const scope = JSON.parse(scopeText), reference = parseAgentNetMediaKey(key);
  if (!reference || !scope.sharedTaskId || reference.slot !== scope.slot || reference.networkId !== scope.networkId
    || (reference.sharedTask && reference.sharedTask.sharedTaskId !== scope.sharedTaskId)) throw new Error('AGENT_NET_MEDIA_SCOPE_MISMATCH');
  await remove(reference.id); assertCurrent();
}
/** Native ports expose named engines, never seeds/tokens; each handle is scoped by the owning Auth generation. */
export async function createAgentNetSharing(configText, host) {
  const config = JSON.parse(configText);
  let closed = false, live = null, renewal = null;
  const guard = () => { if (closed) throw new Error('AGENT_NET_SHARING_CLOSED'); host.check(); };
  const command = (engine, input) => {
    guard(); const response = JSON.parse(host.command(engine, JSON.stringify(input)));
    if (!response.ok) throw new Error(response.code || 'AGENT_NET_ENGINE_FAILED');
    return response.value;
  };
  const signer = engine => ({ identity: command(engine, { op: 'identity' }),
    sign: async text => command(engine, { op: 'sign', text }), random: async () => command(engine, { op: 'random' }) });
  const businessSigner = signer('business'); let applicant = null, lease = null;
  const verify = (key, text, signature) => command('business', { op: 'verify', key, text, signature }) === true;
  const verifyCertificate = (root, value, now = Date.now()) => certificatePolicyValid(value, now)
    && verify(root, certificatePayload(value), value.signature);
  const verifyDelegation = (root, value, now = Date.now()) => delegationPolicyValid(value, now)
    && verifyCertificate(root, value.issuerCertificate, now)
    && !value.executors?.some(e => !verifyCertificate(root, e.certificate, value.issuedAt))
    && verify(value.issuerCertificate.signingKey, delegationPayload(value), value.signature);
  const fetch = async (address, options = {}) => {
    guard(); if (options.signal?.aborted) throw new Error('AGENT_NET_CANCELLED');
    const binary = options.body instanceof Uint8Array;
    const response = JSON.parse(await host.request(address, options.method || 'GET', JSON.stringify(options.headers || {}),
      binary ? toBase64Url(options.body) : options.body || '', binary));
    guard(); if (options.signal?.aborted) throw new Error('AGENT_NET_CANCELLED');
    const bytes = fromBase64Url(response.body);
    return { ok: response.status >= 200 && response.status < 300, status: response.status,
      headers: { get(name) { const key = Object.keys(response.headers || {}).find(k => k.toLowerCase() === name.toLowerCase()); return key ? response.headers[key] : null; } },
      json: async () => JSON.parse(new TextDecoder().decode(bytes)), arrayBuffer: async () => bytes.buffer };
  };
  const wires = new Set();
  const createWebSocket = (address, headers) => {
    guard();
    const socket = { readyState: 0, bufferedAmount: 0, binaryType: 'arraybuffer', onmessage: null, onerror: null, onclose: null,
      send(data) { guard(); wire.send(typeof data === 'string' ? data : toBase64Url(data), typeof data !== 'string'); },
      close() { wire.close(); wires.delete(wire); } };
    const wire = host.socket(address, JSON.stringify(headers), {
      open() { socket.readyState = 1; }, message(data, binary) { if (!closed) socket.onmessage?.({ data: binary ? fromBase64Url(data).buffer : data }); },
      error() { socket.onerror?.({ message: 'AGENT_NET_SHARING_NETWORK_ERROR' }); },
      close(code) { socket.readyState = 3; socket.onclose?.({ code }); } });
    wires.add(wire); return socket;
  };
  const business = new AgentNetSharingClient({ base: config.server, networkId: config.networkId, rootPublicKey: config.rootPublicKey,
    privateSharing: config.v === 3, ownerPinnedHttp: config.ownerPinnedHttp === true, signer: businessSigner, assertCurrent: guard,
    hash: bytes => fromBase64Url(host.sha256(toBase64Url(bytes))), fetch,
    getIdentityCard: async nonce => JSON.parse(await host.identityCard(nonce)),
    ...(config.privateMember ? { memberAuthorization: (method, path, body) => host.memberAuthorization(method, path, body) } : {}) });
  const guestSubject = config.v === 3 ? 'guest:' + businessSigner.identity.signingKey
    : agentNetSharingSubject(config.accountId, config.localRegion, config.region);
  const mediaEngine = { command: async input => command('applicant', input), assertCurrent: guard };
  const slot = () => {
    const value = JSON.stringify(['cindy-agent-net/sharing-media-slot/2', config.rootPublicKey, config.networkId, 'shared-task', config.resourceId, null]);
    const hex = Array.from(fromBase64Url(host.sha256(toBase64Url(new TextEncoder().encode(value)))), byte => byte.toString(16).padStart(2, '0')).join('').slice(0, 32);
    return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join('-');
  };
  let mediaActive = 0;
  const guestApi = delegation => new PortableAgentNetClient(config.server, applicant, delegation.issuerCertificate, config.rootPublicKey,
    { delegation, assertCurrent: guard, sha256: bytes => host.sha256(toBase64Url(bytes)), verifyCertificate, verifyDelegation, fetch, createWebSocket });
  const stop = () => {
    if (closed) return; closed = true; clearTimeout(renewal); live?.socket.close(); lease?.close(); business.close();
    for (const wire of wires) wire.close(); wires.clear(); host.destroy();
  };
  const renew = async () => {
    try {
      guard(); const delegation = await lease.acquire(); guard(); const api = guestApi(delegation);
      await live.socket.replaceClient(api); guard(); live.api = api;
      renewal = setTimeout(renew, Math.max(1000, delegation.expiresAt - Date.now() - 60000));
    } catch { if (!closed) renewal = setTimeout(renew, 5000); }
  };
  return {
    subject() { return config.privateMember ? config.subject : guestSubject; },
    async request(path, method, body, timeoutMs = 12000) {
      guard(); const controller = new AbortController();
      let timer;
      try {
        const timeout = new Promise((_, reject) => { timer = setTimeout(() => { controller.abort(); reject(new Error('AGENT_NET_SHARING_REQUEST_TIMEOUT')); }, Math.max(1, Math.min(15000, timeoutMs))); });
        const work = business.request(path, { method, ...(body ? { body: JSON.parse(body) } : {}), signal: controller.signal, isCurrent: () => { guard(); return true; } });
        const value = await Promise.race([work, timeout]); guard(); return JSON.stringify(value);
      } finally { clearTimeout(timer); controller.abort(); }
    },
    async connect() {
      guard(); if (live) throw new Error('AGENT_NET_SHARING_ALREADY_CONNECTED');
      try {
        applicant = signer('applicant');
        const expectedDevice = config.v === 3 ? guestSubject : config.deviceId;
        if (applicant.identity.deviceId !== expectedDevice) throw new Error('AGENT_NET_SHARING_APPLICANT_MISMATCH');
        lease = new AgentNetSharingTransport({ client: business, applicant, assertCurrent: guard, verifyCertificate, verifyDelegation,
          scope: { kind: 'shared-task', resourceId: config.resourceId, networkId: config.networkId, rootPublicKey: config.rootPublicKey,
            hostDeviceId: config.hostDeviceId, memberId: config.memberId, guestSubject } });
        const delegation = await lease.acquire(); guard(); const api = guestApi(delegation);
        const engine = { command: async input => command('transport', input), assertCurrent: guard, destroy: async () => host.destroyEngine('transport') };
        const socket = await AgentNetSocket.openWithBindings({ client: api, scoped: true, userId: config.accountId, assertCurrent: guard,
          bindings: { verifyCertificate, verifyDelegation, createTransport: options => NativeTransport.create(engine, options) } });
        guard(); live = { socket, api };
        socket.on('message', message => { if (!closed) host.message(typeof message === 'string' ? message : message.toString()); });
        socket.on('close', code => { if (!closed) { clearTimeout(renewal); host.close(code || 1006); } });
        socket.on('error', () => { if (!closed) host.error(); });
        renewal = setTimeout(renew, Math.max(1000, delegation.expiresAt - Date.now() - 60000));
      } catch (error) { stop(); throw error; }
    },
    async upload(size, contentType, read) {
      guard(); if (!live || mediaActive >= 2) throw new Error('AGENT_NET_MEDIA_PEER_UNAVAILABLE');
      if (!Number.isSafeInteger(size) || size <= 0 || size > 2 * 1024 * 1024 * 1024) throw new Error('INVALID_MEDIA_SIZE');
      const target = live.socket.scopedPeerTarget(sharedTaskHostPeer(config.resourceId, config.hostDeviceId));
      if (!target) throw new Error('AGENT_NET_MEDIA_SCOPE_MISMATCH');
      mediaActive++;
      try {
        const result = await uploadNativeMedia(live.api, mediaEngine, target.relayId, target.transportKey, size,
          async (offset, length) => { guard(); const bytes = fromBase64Url(await read(offset, length)); guard(); return bytes; },
          { assertCurrent: guard, binding: agentNetMediaBinding(slot()) }); guard();
        const key = buildAgentNetMediaKey({ slot: slot(), networkId: live.api.certificate.networkId, grantId: live.api.delegation.id,
          sharedTask: { sharedTaskId: config.resourceId, deviceId: live.api.identity.deviceId }, id: result.id, headerSha256: result.headerSha256, contentType });
        return JSON.stringify({ key, sha256: result.sha256, size });
      } finally { mediaActive--; }
    },
    async download(key, write) {
      guard(); const reference = parseAgentNetMediaKey(key);
      if (!live || !reference || reference.slot !== slot() || reference.networkId !== config.networkId
        || (reference.sharedTask && reference.sharedTask.sharedTaskId !== config.resourceId) || mediaActive >= 2) throw new Error('AGENT_NET_MEDIA_SCOPE_MISMATCH');
      mediaActive++;
      try {
        const result = await readNativeMedia(live.api, mediaEngine, reference.id, reference.headerSha256,
          async (bytes, offset) => { guard(); await write(toBase64Url(bytes), offset); guard(); },
          { assertCurrent: guard, binding: agentNetMediaBinding(slot()) }); guard();
        return JSON.stringify({ size: result.size, mimeType: reference.contentType });
      } finally { mediaActive--; }
    },
    async deleteMedia(key) {
      guard(); if (!live) throw new Error('AGENT_NET_MEDIA_SOURCE_UNAVAILABLE');
      if (mediaActive >= 2) throw new Error('BACKPRESSURE'); mediaActive++;
      try {
        await deleteScopedAgentNetMedia(key, JSON.stringify({ slot: slot(), networkId: config.networkId, sharedTaskId: config.resourceId }), guard,
          async id => { guard(); await live.api.request('DELETE', '/media/' + id); guard(); });
      } finally { mediaActive--; }
    },
    send(text) { guard(); if (!live) throw new Error('AGENT_NET_SHARING_NOT_CONNECTED'); live.socket.send(text); },
    close: stop,
  };
}
/** Add missing URL inspection to Harmony's existing polyfill, preserving the owner socket's constructor. */
export function installSharingWebApis(parseUrl, queryPairs) {
  class SharingSearchParams {
    constructor(value) { this.pairs = JSON.parse(queryPairs(value)); }
    get(name) { return this.pairs.find(pair => pair[0] === name)?.[1] ?? null; }
    getAll(name) { return this.pairs.filter(pair => pair[0] === name).map(pair => pair[1]); }
    keys() { return this.pairs.map(pair => pair[0]).values(); }
  }
  if (typeof globalThis.URL !== 'function') globalThis.URL = class {
    constructor(value) { Object.assign(this, JSON.parse(parseUrl(String(value)))); }
  };
  if (!Object.getOwnPropertyDescriptor(globalThis.URL.prototype, 'origin'))
    Object.defineProperty(globalThis.URL.prototype, 'origin', { get() { return this.protocol + '//' + this.host; }, configurable: true });
  if (!Object.getOwnPropertyDescriptor(globalThis.URL.prototype, 'searchParams'))
    Object.defineProperty(globalThis.URL.prototype, 'searchParams', { get() { return new SharingSearchParams((this.search || '').replace(/^\?/, '')); }, configurable: true });
}
