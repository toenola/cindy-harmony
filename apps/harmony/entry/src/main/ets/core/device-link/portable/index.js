var __defProp = Object.defineProperty;
var __defNormalProp = (obj, key3, value) => key3 in obj ? __defProp(obj, key3, { enumerable: true, configurable: true, writable: true, value }) : obj[key3] = value;
var __publicField = (obj, key3, value) => __defNormalProp(obj, typeof key3 !== "symbol" ? key3 + "" : key3, value);

// native/portable/polyfill.ts
if (typeof globalThis.TextEncoder !== "function") globalThis.TextEncoder = class {
  encode(value = "") {
    const text2 = String(value), bytes = [];
    for (let i = 0; i < text2.length; i++) {
      let cp = text2.codePointAt(i);
      if (cp > 65535) i++;
      else if (cp >= 55296 && cp <= 57343) cp = 65533;
      if (cp <= 127) bytes.push(cp);
      else if (cp <= 2047) bytes.push(192 | cp >> 6, 128 | cp & 63);
      else if (cp <= 65535) bytes.push(224 | cp >> 12, 128 | cp >> 6 & 63, 128 | cp & 63);
      else bytes.push(240 | cp >> 18, 128 | cp >> 12 & 63, 128 | cp >> 6 & 63, 128 | cp & 63);
    }
    return new Uint8Array(bytes);
  }
};
if (typeof globalThis.TextDecoder !== "function") globalThis.TextDecoder = class {
  decode(input = new Uint8Array()) {
    const bytes = input instanceof ArrayBuffer ? new Uint8Array(input) : new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
    return decodeURIComponent(Array.from(bytes, (c) => "%" + c.toString(16).padStart(2, "0")).join(""));
  }
};
if (typeof globalThis.performance === "undefined") globalThis.performance = { now: () => Date.now() };
if (typeof globalThis.AbortController !== "function") globalThis.AbortController = class {
  constructor() {
    __publicField(this, "signal", {
      aborted: false,
      listeners: /* @__PURE__ */ new Set(),
      addEventListener(name, fn) {
        if (name === "abort") this.listeners.add(fn);
      },
      removeEventListener(name, fn) {
        this.listeners.delete(fn);
      }
    });
  }
  abort() {
    if (this.signal.aborted) return;
    this.signal.aborted = true;
    this.signal.listeners.forEach((fn) => fn());
    this.signal.listeners.clear();
  }
};

// ../../packages/agent-net-protocol/src/sharingOrigins.ts
function stripTrailingSlashes(value) {
  let end = value.length;
  while (end > 0 && value.charCodeAt(end - 1) === 47) end--;
  return value.slice(0, end);
}

// ../../packages/agent-net-protocol/src/index.ts
var MAX_FRAME_BYTES = 64 * 1024;
var MAX_CONTROL_BYTES = 1024 * 1024;
var MAX_MEDIA_OBJECT_BYTES = 2 * 1024 * 1024 * 1024 + MAX_FRAME_BYTES;
var MAX_MEDIA_BINARY_CHUNK_BYTES = 8 * 1024 * 1024;
var MEDIA_PLAINTEXT_CHUNK_BYTES = 1024 * 1024;
var MEDIA_ENCRYPTED_HEADER_BYTES = 221;
var MEDIA_TRANSFER_DIRECT = "direct-v1";
var MEDIA_TRANSFER_HEADER = "x-agent-net-media-transfer";
function directMediaRequestValid(value) {
  if (!value || typeof value !== "object") return false;
  const request = value;
  if (!["GET", "PUT", "POST"].includes(request.method) || typeof request.url !== "string" || request.url.length > 4096 || !Number.isSafeInteger(request.expiresAt) || !request.headers || typeof request.headers !== "object" || Array.isArray(request.headers)) return false;
  const headers = Object.entries(request.headers);
  if (headers.length > 16 || !headers.every(([name, header]) => /^[A-Za-z0-9-]{1,64}$/.test(name) && typeof header === "string" && header.length <= 1024 && !/[\r\n]/.test(header) && !["authorization", "cookie", "host"].includes(name.toLowerCase()))) return false;
  try {
    const url = new URL(request.url);
    return (url.protocol === "https:" || url.protocol === "http:") && !url.username && !url.password && !url.hash;
  } catch {
    return false;
  }
}
function agentNetMediaBinding(slot) {
  if (!/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(slot)) throw new Error("INVALID_MEDIA_SCOPE");
  return "cindy-agent-net/media-scope/3/" + slot;
}
function buildAgentNetMediaKey(value) {
  let key3 = `agent-net-v3/${value.slot}/${encodeURIComponent(value.networkId)}/${value.grantId ?? "-"}/${value.id}/${value.headerSha256}/${encodeURIComponent(value.contentType)}`;
  if (value.sharedTask) {
    const { sharedTaskId, deviceId } = value.sharedTask;
    if (![sharedTaskId, deviceId].every((id) => /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(id))) throw new Error("INVALID_MEDIA_SCOPE");
    const receipt = Array.from(key3, (c) => c.charCodeAt(0).toString(16).padStart(2, "0")).join("");
    key3 = `cindy/device-link/shared-task/${sharedTaskId}/${deviceId}/an3-${receipt}`;
  }
  if (!parseAgentNetMediaKey(key3)) throw new Error("INVALID_MEDIA_KEY");
  return key3;
}
function parseAgentNetMediaKey(key3) {
  if (key3.length > 4096) return null;
  let sharedTask;
  const scoped = /^cindy\/device-link\/shared-task\/([A-Za-z0-9][A-Za-z0-9._:-]{0,127})\/([A-Za-z0-9][A-Za-z0-9._:-]{0,127})\/an3-((?:[0-9a-f]{2})+)$/.exec(key3);
  if (scoped) {
    const bytes = scoped[3].match(/../g).map((pair) => parseInt(pair, 16));
    if (bytes.some((value) => value < 33 || value > 126)) return null;
    key3 = String.fromCharCode(...bytes);
    sharedTask = { sharedTaskId: scoped[1], deviceId: scoped[2] };
  }
  const match = /^agent-net-v3\/([0-9a-f-]{36})\/([^/]{1,384})\/(-|[0-9a-f-]{36})\/([0-9a-f-]{36})\/([0-9a-f]{64})\/([^/]{1,512})$/.exec(key3);
  if (!match) return null;
  try {
    const contentType = decodeURIComponent(match[6]), networkId = decodeURIComponent(match[2]);
    if (!ID_PATTERN.test(networkId)) return null;
    if (!/^[A-Za-z0-9!#$&^_.+-]+\/[A-Za-z0-9!#$&^_.+-]+(?:;[\x20-\x7e]*)?$/.test(contentType) || contentType.length > 128) return null;
    return {
      slot: match[1],
      networkId,
      ...match[3] !== "-" ? { grantId: match[3] } : {},
      id: match[4],
      headerSha256: match[5],
      contentType,
      ...sharedTask ? { sharedTask } : {}
    };
  } catch {
    return null;
  }
}
var MEDIA_NETWORK_QUOTA_BYTES = 8 * 1024 * 1024 * 1024;
var CERT_LIFETIME_MS = 14 * 24 * 60 * 60 * 1e3;
var PRIVATE_MEMBERSHIP_EXPIRES_AT = Number.MAX_SAFE_INTEGER;
var MAX_GRANT_LIFETIME_MS = 30 * 60 * 1e3;
var ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,127}$/;
var KEY_PATTERN = /^[A-Za-z0-9_-]{43}$/;
function delegationPrincipalMatches(a, b) {
  return a.id === b.id && a.kind === b.kind && a.networkId === b.networkId && a.resourceId === b.resourceId && a.hostDeviceId === b.hostDeviceId && a.guestDeviceId === b.guestDeviceId && a.guestSigningKey === b.guestSigningKey && a.guestTransportKey === b.guestTransportKey && a.issuerCertificate.signingKey === b.issuerCertificate.signingKey && a.issuerCertificate.transportKey === b.issuerCertificate.transportKey && a.scope?.memberId === b.scope?.memberId && a.scope?.guestSubject === b.scope?.guestSubject && a.scope?.memberVersion === b.scope?.memberVersion;
}
function delegationEndpointCertificate(d, deviceId, now2 = Date.now()) {
  if (deviceId === d.hostDeviceId) return d.issuerCertificate;
  return d.executors?.find((e) => e.certificate.deviceId === deviceId && e.expiresAt > now2)?.certificate;
}
function delegationVisibleTo(d, identity, own) {
  if (own) return delegationPrincipalMatches(d, own) && d.guestDeviceId === identity.deviceId && d.guestSigningKey === identity.signingKey && d.guestTransportKey === identity.transportKey;
  const endpoint3 = delegationEndpointCertificate(d, identity.deviceId);
  return endpoint3?.signingKey === identity.signingKey && endpoint3.transportKey === identity.transportKey;
}
function delegationRequestPolicyValid(value, host, now2 = Date.now()) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const r = value;
  const id = (v) => typeof v === "string" && ID_PATTERN.test(v);
  const key3 = (v) => typeof v === "string" && KEY_PATTERN.test(v) && /[AEIMQUYcgkosw048]$/.test(v);
  return Object.keys(r).length === 11 && id(r.id) && (r.kind === "shared-task" || r.kind === "provider-share") && r.hostDeviceId === host.deviceId && r.networkId === host.networkId && id(r.resourceId) && id(r.guestDeviceId) && key3(r.guestSigningKey) && key3(r.guestTransportKey) && delegationScopeValid(r.scope) && Number.isSafeInteger(r.requestedAt) && r.requestedAt >= 0 && r.requestedAt <= now2 + 3e4 && Number.isSafeInteger(r.expiresAt) && r.expiresAt > now2 && r.expiresAt > r.requestedAt && r.expiresAt - r.requestedAt <= MAX_GRANT_LIFETIME_MS;
}
function delegationScopeValid(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const s = value;
  return Object.keys(s).length === 3 && typeof s.memberId === "string" && ID_PATTERN.test(s.memberId) && typeof s.guestSubject === "string" && ID_PATTERN.test(s.guestSubject) && Number.isSafeInteger(s.memberVersion) && s.memberVersion >= 1;
}
function certificatePayload(c) {
  return JSON.stringify([
    "cindy-agent-net/certificate/2",
    c.v,
    c.networkId,
    c.subject,
    c.deviceId,
    c.signingKey,
    c.transportKey,
    c.role,
    c.issuedAt,
    c.expiresAt,
    c.serial
  ]);
}
function certificatePolicyValid(value, now2 = Date.now()) {
  if (!value || typeof value !== "object") return false;
  const c = value;
  const id = (v) => typeof v === "string" && ID_PATTERN.test(v);
  const key3 = (v) => typeof v === "string" && KEY_PATTERN.test(v) && /[AEIMQUYcgkosw048]$/.test(v);
  const time2 = (v) => Number.isSafeInteger(v) && Number(v) >= 0;
  return Object.keys(c).length === 11 && c.v === 2 && id(c.networkId) && id(c.subject) && id(c.deviceId) && id(c.serial) && key3(c.signingKey) && key3(c.transportKey) && ["owner", "member"].includes(c.role) && time2(c.issuedAt) && time2(c.expiresAt) && c.issuedAt <= now2 + 3e4 && c.expiresAt > now2 && c.expiresAt > c.issuedAt && (c.networkId.startsWith("private:") || c.expiresAt - c.issuedAt <= CERT_LIFETIME_MS) && typeof c.signature === "string";
}
function guestRequestPath(path, networkId, delegationId) {
  return JSON.stringify(["cindy-agent-net/guest-request/2", path, networkId, delegationId]);
}
function requestPayload(method, path, bodyHash, p) {
  return JSON.stringify(["cindy-agent-net/request/2", method.toUpperCase(), path, bodyHash, p.at, p.nonce]);
}
function encodeDatagrams(deviceId, datagrams) {
  if (!ID_PATTERN.test(deviceId)) throw new Error("INVALID_DATAGRAM_FRAME");
  const id = Uint8Array.from(deviceId, (character) => character.charCodeAt(0));
  if (!ID_PATTERN.test(deviceId) || id.length > 255 || datagrams.length === 0) throw new Error("INVALID_DATAGRAM_FRAME");
  let size = 2 + id.length;
  for (const packet of datagrams) {
    if (packet.length === 0 || packet.length > 65507) throw new Error("INVALID_DATAGRAM_FRAME");
    size += 2 + packet.length;
  }
  if (size > MAX_FRAME_BYTES) throw new Error("INVALID_DATAGRAM_FRAME");
  const frame = new Uint8Array(size);
  frame[0] = 1;
  frame[1] = id.length;
  frame.set(id, 2);
  let at = 2 + id.length;
  for (const packet of datagrams) {
    frame[at++] = packet.length >>> 8;
    frame[at++] = packet.length & 255;
    frame.set(packet, at);
    at += packet.length;
  }
  return frame;
}
function decodeDatagrams(frame) {
  if (frame.length < 5 || frame.length > MAX_FRAME_BYTES || frame[0] !== 1 || frame[1] === 0) return null;
  let at = 2 + frame[1];
  if (at >= frame.length) return null;
  const encodedId = frame.subarray(2, at);
  if (encodedId.some((byte) => byte > 127)) return null;
  const deviceId = String.fromCharCode(...encodedId);
  if (!ID_PATTERN.test(deviceId)) return null;
  const datagrams = [];
  while (at < frame.length) {
    if (at + 2 > frame.length) return null;
    const length = frame[at] * 256 + frame[at + 1];
    at += 2;
    if (length === 0 || length > 65507 || at + length > frame.length) return null;
    datagrams.push(frame.subarray(at, at + length));
    at += length;
  }
  return datagrams.length ? { deviceId, datagrams } : null;
}

// ../../packages/device-link-protocol/src/sharedTask.ts
var SHARED_TASK_RELAY_CAPABILITY = "shared-task-v2";
function sharedTaskDeviceId(value) {
  if (typeof value !== "string" || value.length < 1 || value.length > 128) throw new Error("Invalid sharedTask device identifier");
  return value;
}
function sharedTaskIdentifier(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(value)) throw new Error("Invalid sharedTask identifier");
  return value;
}
function endpoint(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid sharedTask endpoint");
  const row = value;
  if (row.role === "host" && row.memberId === void 0) return { role: "host" };
  if (row.role === "guest") return { role: "guest", memberId: sharedTaskIdentifier(row.memberId) };
  throw new Error("Invalid sharedTask endpoint");
}
function parseSharedTaskScope(value, withSource = false) {
  try {
    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    const row = value;
    const scope = { sharedTaskId: sharedTaskIdentifier(row.sharedTaskId), target: endpoint(row.target) };
    if (withSource) {
      scope.source = endpoint(row.source);
      if (scope.source.role === scope.target.role) return null;
    }
    return scope;
  } catch {
    return null;
  }
}

// ../../packages/device-link-protocol/src/providerShare.ts
var PROVIDER_SHARE_RELAY_CAPABILITY = "provider-share-v1";
function providerShareIdentifier(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(value)) throw new Error("Invalid providerShare identifier");
  return value;
}
function endpoint2(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid providerShare endpoint");
  const row = value;
  if (row.role === "host" && row.memberId === void 0) return { role: "host" };
  if (row.role === "guest") return { role: "guest", memberId: providerShareIdentifier(row.memberId) };
  throw new Error("Invalid providerShare endpoint");
}
function parseProviderShareScope(value, withSource = false) {
  try {
    if (!value || typeof value !== "object" || Array.isArray(value)) return null;
    const row = value;
    const scope = { shareId: providerShareIdentifier(row.shareId), target: endpoint2(row.target) };
    if (withSource) {
      scope.source = endpoint2(row.source);
      if (scope.source.role === scope.target.role) return null;
    }
    return scope;
  } catch {
    return null;
  }
}

// ../../packages/device-link-protocol/src/protocol.ts
var PROTOCOL_VERSION = 1;
var MAX_FRAME_BYTES2 = 2 * 1024 * 1024;
var WS_MAX_PAYLOAD_BYTES = 4 * 1024 * 1024;
var ROUTED_KINDS = /* @__PURE__ */ new Set([
  "link-open",
  "link-accept",
  "link-close",
  "invoke",
  "invoke-result",
  "push"
]);
var CONTROL_KINDS = /* @__PURE__ */ new Set(["link-open", "invoke"]);
var SERVER_CAPABILITY_NOTIFY = "notify";

// ../../packages/device-link/src/providerSharePeer.ts
var TAG = "provider-share";
function key(peer) {
  return JSON.stringify([TAG, peer.shareId, peer.role, peer.role === "guest" ? peer.memberId : null, peer.deviceId]).padEnd(129, "~");
}
function providerShareHostPeer(shareId, deviceId) {
  return key({ shareId: providerShareIdentifier(shareId), role: "host", deviceId: sharedTaskDeviceId(deviceId) });
}
function providerShareGuestPeer(shareId, memberId, deviceId) {
  return key({ shareId: providerShareIdentifier(shareId), role: "guest", memberId: providerShareIdentifier(memberId), deviceId: sharedTaskDeviceId(deviceId) });
}
function parseProviderSharePeer(value) {
  if (typeof value !== "string" || value.length <= 128 || value.length > 2048) return null;
  try {
    const parts = JSON.parse(value.replace(/~+$/, ""));
    if (!Array.isArray(parts) || parts.length !== 5 || parts[0] !== TAG) return null;
    const [, share, role, member, device] = parts;
    const shareId = providerShareIdentifier(share);
    const deviceId = sharedTaskDeviceId(device);
    let peer;
    if (role === "host" && member === null) peer = { shareId, role, deviceId };
    else if (role === "guest") peer = { shareId, role, deviceId, memberId: providerShareIdentifier(member) };
    else return null;
    return key(peer) === value ? peer : null;
  } catch {
    return null;
  }
}

// ../../packages/device-link/src/sharedTaskPeer.ts
function key2(peer) {
  return JSON.stringify([peer.sharedTaskId, peer.role, peer.role === "guest" ? peer.memberId : null, peer.deviceId]).padEnd(129, "~");
}
function sharedTaskHostPeer(sharedTaskId, deviceId) {
  return key2({ sharedTaskId: sharedTaskIdentifier(sharedTaskId), role: "host", deviceId: sharedTaskDeviceId(deviceId) });
}
function sharedTaskGuestPeer(sharedTaskId, memberId, deviceId) {
  return key2({ sharedTaskId: sharedTaskIdentifier(sharedTaskId), role: "guest", memberId: sharedTaskIdentifier(memberId), deviceId: sharedTaskDeviceId(deviceId) });
}
function parseSharedTaskPeer(value) {
  if (typeof value !== "string" || value.length <= 128 || value.length > 2048) return null;
  try {
    const parts = JSON.parse(value.replace(/~+$/, ""));
    if (!Array.isArray(parts) || parts.length !== 4) return null;
    const [task, role, member, device] = parts;
    const sharedTaskId = sharedTaskIdentifier(task);
    const deviceId = sharedTaskDeviceId(device);
    let peer;
    if (role === "host" && member === null) peer = { sharedTaskId, role, deviceId };
    else if (role === "guest") peer = { sharedTaskId, role, deviceId, memberId: sharedTaskIdentifier(member) };
    else return null;
    return key2(peer) === value ? peer : null;
  } catch {
    return null;
  }
}

// ../../packages/device-link/src/filePeerRuntime.ts
var RPC_BODY_MAX_BYTES = 1024 * 1024;

// ../../packages/device-link/src/filePeer.ts
var FILE_PEER_CHANNEL = "device-link:file-peer";
var FILE_PEER_RANGE_BYTES = 1024 * 1024;
var FILE_PEER_CHUNK_BYTES = 16 * 1024;
var FILE_PEER_MAX_BYTES = 2 * 1024 * 1024 * 1024;
var FILE_PEER_IDLE_MS = 5 * 6e4;
var FILE_PEER_WRITE_BATCH_BYTES = 256 * 1024;
var FILE_PEER_STREAM_RPC_MAX_TIMEOUT_MS = 60 * 6e4;
var STREAM_RPC_MAX_PAYLOAD = 4 * 1024 * 1024;
var STREAM_RPC_MAX_BODY_BASE64 = Math.ceil(RPC_BODY_MAX_BYTES / 3) * 4;

// ../../packages/device-link/src/machineStatus.ts
var MACHINE_STATUS_CHANNEL = "maker:machine:status";

// ../../packages/device-link/src/agentNetSwitch.ts
var AGENT_NET_SWITCH_CHANNEL = "device-link:agent-net-switch:v1";
var AGENT_NET_SWITCH_TIMEOUT_MS = 15e3;

// ../../packages/device-link/src/providerGroup.ts
var PROVIDER_GROUP_REMOTE_CHANNEL = "provider-group:remote";

// ../../packages/device-link/src/remoteAgent.ts
var REMOTE_AGENT_CHANNEL = "maker:remote-agent:v1";
var REMOTE_AGENT_KINDS = ["claude-code", "codex", "pi"];
var REMOTE_AGENT_PLUGIN_ENGINE_KIND = "acp";
var REMOTE_AGENT_ENGINE_KINDS = [...REMOTE_AGENT_KINDS, REMOTE_AGENT_PLUGIN_ENGINE_KIND];
var REMOTE_AGENT_UPLOAD_CHUNK_BYTES = 512 * 1024;
var REMOTE_AGENT_MAX_PAYLOAD_BYTES = 64 * 1024 * 1024;
var REMOTE_AGENT_MAX_UPLOAD_CHUNKS = REMOTE_AGENT_MAX_PAYLOAD_BYTES / REMOTE_AGENT_UPLOAD_CHUNK_BYTES;
var REMOTE_AGENT_MAX_INLINE_PAYLOAD_CHARS = 1024 * 1024;
var REMOTE_AGENT_READ_MAX_BYTES = 512 * 1024;
var REMOTE_AGENT_POLL_MAX_BYTES = 1536 * 1024;
var REMOTE_AGENT_POLL_MIN_BYTES = 64 * 1024;
var REMOTE_AGENT_MAX_PUSH_CHARS = 3 * 1024 * 1024;
var READ_RESULT_ACCEPT_BYTES = 2 * 1024 * 1024;

// ../../packages/device-link/src/orcaRemoteWorker.ts
var ORCA_REMOTE_WORKER_CAPS_CHANNEL = "maker:orca:remote-worker:caps";
var ORCA_REMOTE_WORKER_MODELS_CHANNEL = "maker:orca:remote-worker:models";
var ORCA_REMOTE_WORKER_OPEN_CHANNEL = "maker:orca:remote-worker:open";
var ORCA_REMOTE_WORKER_RELEASE_CHANNEL = "maker:orca:remote-worker:release";
var ORCA_REMOTE_WORKER_BRIDGE_CHANNEL = "maker:orca:remote-worker:bridge";
var ORCA_EXECUTION_DEVICES_CHANNEL = "maker:orca:execution-devices";
var ORCA_REMOTE_WORKER_OPEN_TIMEOUT_MS = 6e4;

// ../../packages/device-link/src/taskMigration.ts
var TASK_MIGRATION_CHANNEL = "maker:task-copy";
var TASK_MIGRATION_ESTIMATE_TIMEOUT_MS = 3 * 6e4;
var TASK_MIGRATION_RECEIVE_TIMEOUT_MS = 30 * 6e4;

// ../../packages/device-link/src/setupSnapshot.ts
var SETUP_SNAPSHOT_CHANNEL = "maker:setup-snapshot";
var SETUP_SNAPSHOT_TIMEOUT_MS = 6e4;
var SETUP_SNAPSHOT_LIMITS = {
  settingsGroups: 64,
  settingsGroupBytes: 64 * 1024,
  rendererPrefs: 128,
  rendererPrefBytes: 64 * 1024,
  plugins: 300,
  pluginSources: 32,
  skills: 500,
  mcpServers: 100,
  providers: 64,
  providerBytes: 128 * 1024,
  builtinTools: 64,
  hints: 64,
  sshHosts: 200
};

// ../../packages/device-link/src/setupTransfer.ts
var SETUP_TRANSFER_CHANNEL = "maker:setup-transfer";
var SETUP_TRANSFER_TIMEOUT_MS = 5 * 6e4;
var SETUP_TRANSFER_CONFIRM_MS = 2 * 6e4;

// ../../packages/device-link/src/companionCloud.ts
var COMPANION_CLOUD_CAPS_CHANNEL = "maker:companion-cloud:caps";
var COMPANION_LIVE_CHANNEL = "maker:companion-live:read";
var COMPANION_CLOUD_TARGETS_CHANNEL = "maker:companion-cloud:targets";
var COMPANION_CLOUD_HAND_OVER_CHANNEL = "maker:companion-cloud:hand-over";
var COMPANION_CLOUD_HAND_OVER_TIMEOUT_MS = 7 * 6e4;
var COMPANION_CLOUD_MERGE_CHANNEL = "maker:companion-cloud:merge";
var COMPANION_CLOUD_MERGE_TIMEOUT_MS = 10 * 6e4;
var COMPANION_CLOUD_FLUSH_CHANNEL = "maker:companion-cloud:flush";

// ../../packages/device-link/src/remoteResources.ts
var REMOTE_RESOURCE_MANIFEST_CHANNEL = "maker:remote-resources:manifest";
var REMOTE_RESOURCE_LIST_CHANNEL = "maker:remote-resources:list";
var REMOTE_RESOURCE_GET_CHANNEL = "maker:remote-resources:get";
var REMOTE_RESOURCE_INVOKE_CHANNEL = "maker:remote-resources:invoke";
var REMOTE_RESOURCE_CHANNELS = [
  REMOTE_RESOURCE_MANIFEST_CHANNEL,
  REMOTE_RESOURCE_LIST_CHANNEL,
  REMOTE_RESOURCE_GET_CHANNEL,
  REMOTE_RESOURCE_INVOKE_CHANNEL
];
var MAX_ACTION_INPUT_BYTES = 64 * 1024;

// ../../packages/device-link/src/remoteDesktopIce.ts
var REMOTE_DESKTOP_ICE_CONFIG_TIMEOUT_MS = 8e3;
var REMOTE_DESKTOP_OFFER_BUDGET = {
  captureReadyMs: 1e4,
  platformStatusMs: 8e3,
  // Windows Node-API probe: pipe open 3s, write 5s, and ready read 5s.
  platformHandshakeMs: 13e3,
  sourcesMs: 5e3,
  hostMs: 18e3
};
var REMOTE_DESKTOP_INVOKE_MS = REMOTE_DESKTOP_OFFER_BUDGET.captureReadyMs + REMOTE_DESKTOP_OFFER_BUDGET.platformStatusMs + REMOTE_DESKTOP_OFFER_BUDGET.platformHandshakeMs + REMOTE_DESKTOP_OFFER_BUDGET.sourcesMs + REMOTE_DESKTOP_OFFER_BUDGET.hostMs + 5e3;
var REMOTE_DESKTOP_NETWORK = {
  iceConfigMs: REMOTE_DESKTOP_ICE_CONFIG_TIMEOUT_MS,
  iceConfigBridgeMs: 500,
  maxCandidates: 128,
  batchSize: 16,
  pollMs: 250,
  exchangeMs: 3e4,
  disconnectedMs: 5e3,
  answerMs: REMOTE_DESKTOP_INVOKE_MS + 2e3,
  connectMs: 15e3,
  legacyGatherMs: 5e3,
  stableMs: 3e4,
  retryMs: [1e3, 3e3, 8e3]
};

// ../../packages/device-link/src/allowlist.ts
var DL_SUBSCRIBE_CHANNEL = "device-link:subscribe";
var DL_UNSUBSCRIBE_CHANNEL = "device-link:unsubscribe";
var DL_HISTORY_MESSAGES_CHANNEL = "local-db:history:messages";
var DL_HISTORY_QUERY_CHANNEL = "local-db:history:query";
var DL_SESSION_HANDOFF_CHANNEL = "maker:session:handoff";
var DL_SESSION_REFERENCE_CAPABILITY_CHANNEL = "maker:input:session-reference-capability";
var DL_MEDIA_FETCH_CHANNEL = "device-link:media:fetch";
var DL_USAGE_WIDGET_SNAPSHOT_CHANNEL = "device-link:usage-widget:snapshot:v1";
var DL_VOICE_TRANSCRIBE_CHANNEL = "device-link:voice:transcribe";
var DL_VOICE_CREDENTIAL_SYNC_CHANNEL = "device-link:voice:credential-sync";
var DL_TELEGRAM_STATUS_CHANNEL = "device-link:telegram:status";
var DL_TELEGRAM_SET_ONLINE_CHANNEL = "device-link:telegram:set-online";
var DL_VOICE_DICTIONARY_LEARNING_CHANNEL = "device-link:voice:dictionary-learning";
var DL_VOICE_DICTIONARY_GET_CHANNEL = "device-link:voice:dictionary:get";
var CORE_INVOKE_CHANNELS = [
  // —— 会话生命周期 ——
  "maker:create-session",
  "maker:close-session",
  "maker:abort-session",
  "maker:send",
  // Task-bound official MCP App bridge. No credentials or arbitrary endpoint selection.
  "maker:mcp-apps:v1",
  DL_SESSION_HANDOFF_CHANNEL,
  "maker:steer",
  // 控制端输入框开始打字时，请被控端提前启动该任务的 Agent。被控端只对普通任务、
  // 本机运行的 Agent 生效，限量并空闲回收；旧被控端 CHANNEL_NOT_ALLOWED → 控制端静默忽略。
  "maker:session:prewarm",
  "maker:list-active",
  "maker:any-session-in-turn",
  "maker:session-in-turn",
  // Review evidence and the Reviewer session are created on the data-owning
  // device. The handler remains host-owned; this only permits the explicit
  // start request to cross the device-link tunnel.
  "maker:review:start",
  // —— 输入队列(input queue 全集,无本机副作用)——
  DL_SESSION_REFERENCE_CAPABILITY_CHANNEL,
  "maker:input:get-projection",
  "maker:input:enqueue",
  "maker:input:compact",
  // 手动压缩(pi 原生 compact,capability-aware):上下文环 / 会话菜单对远程 pi 会话
  // 隧道到被控端执行。业务 handler 无 sender / 本机 UI 副作用,真相在被控端。
  // 长 LLM 摘要请求可能远超默认 30s → INVOKE_TIMEOUT_OVERRIDES_MS 覆盖(见下)。
  "maker:compact-session",
  "maker:input:steer",
  "maker:input:stop",
  "maker:input:resume",
  "maker:images:retry",
  "maker:input:retry-last-error",
  "maker:input:clear-error",
  "maker:input:cancel-usage-limit-wait",
  "maker:input:remove",
  "maker:input:update-text",
  // 整条内容替换(文本+附件),手机端排队消息复用 composer 编辑;老被控端无 handler →
  // CHANNEL_NOT_ALLOWED,控制端按「仅文本变化降级 update-text / 附件变化提示升级」处理。
  "maker:input:update-content",
  "maker:input:move",
  "maker:input:set-expanded",
  "maker:input:set-interaction-lock",
  "maker:input:set-edit-lock",
  "maker:input:clear-session",
  // device-link:auth error 重试失败/放弃时控制端调此补落被控端 DB;被控端 main 执行无 sender 依赖。
  "maker:persist-turn-error-deferred",
  // —— 交互审批(permission / ask / plan)——
  "maker:resolve-interaction",
  // 打开/重连/刷新会话时拉当前挂起交互快照,重建可操作面板(只读)。
  "maker:get-pending-interactions",
  // —— 运行时切换 ——
  "maker:set-model",
  // 同一会话 Claude Code / Codex 切换采用 pending intent：写入口只登记意图，
  // 只读入口供控制端重连后恢复 main 权威状态；两者都无 event.sender / 本机 UI 副作用。
  "maker:switch-session-agent",
  "maker:get-session-agent-switch-intent",
  "maker:set-effort",
  "maker:set-permission-mode",
  "maker:set-fast-mode",
  // Pi 本机模型思考开关。runtime-only，无 session 列；老被控端无 handler →
  // CHANNEL_NOT_ALLOWED，控制端按 capabilities.thinkingToggle 隐藏入口。
  "maker:set-thinking-enabled",
  // 计划模式一级开关(runtime-only, 持久化经 dispatch persistRemoteSetting 回流)。
  // 老被控端无 handler → CHANNEL_NOT_ALLOWED → 控制端 UI 本就按 capabilities.planMode 缺失隐藏入口。
  "maker:set-plan-mode",
  // 任务级工作上下文窗口档位(会话级设置, 无本机 shell/UI 副作用; 控制端 DB 是被控端那份,
  // 写本机不生效)。被控端落库并应用到活实例。老被控端无 handler → CHANNEL_NOT_ALLOWED
  // → 控制端提示「该设备版本不支持」并保留原档位。
  "maker:set-context-window-budget",
  // 任务级窗口边界的只读查询(路由默认/物理上限/该路由模型级上限):控制端打开远程档位
  // 菜单时拉一次,才能给出「更大」的档位。无 event.sender / 无本机副作用,不写任何存储。
  // 老被控端无 handler → CHANNEL_NOT_ALLOWED → 控制端退回「只允许收紧」。
  "maker:get-context-window-bounds",
  "maker:set-extra-dirs",
  "maker:set-writable-dirs",
  // Pi 原生分支树:只读快照 + 当前会话内导航。导航业务 handler 在被控端原子同步
  // SDK leaf 与 SQLite 可见时间线，不依赖 sender/窗口，真相也只在被控端。
  "maker:get-session-tree",
  "maker:navigate-session-tree",
  // 会话「非选中模型」effort/fast 写穿(控制端 → 被控端):控制端纯显示,改非选中行的预设记忆时
  // 通知被控端,被控端调它原来的本地 setter(setSessionModelEffort/Fast)写真实存储。选中模型仍走
  // maker:set-model/effort/fast-mode + sessions:patched,不经此 channel。被控端转发给自身 renderer
  // 执行(无 sender 依赖、无本机副作用)。老被控端无 handler → CHANNEL_NOT_ALLOWED → 控制端吞掉降级。
  "maker:set-session-model-pref",
  // —— 能力查询 ——
  "maker:get-capabilities",
  "maker:list-available-agents",
  // 插件提供的执行引擎(docs/plans/acp-plugin-bridge.md，只读)：手机在被控电脑上新建 / 切换到插件
  // 引擎时读那台的引擎列表(名称、图标、模型、思考深度、工作模式)；刷新只请那台的插件重新上报模型
  // (插件各自冷却)。数据真相在被控端，无 sender 依赖、无本机 UI 副作用。老被控端无此准入 →
  // CHANNEL_NOT_ALLOWED → 控制端按「没有插件引擎」隐藏入口。
  "maker:list-plugin-engines",
  "maker:refresh-plugin-engines",
  "maker:get-plugin-engine-usage",
  // device-link 远程草稿镜像(只读):控制端为被控设备新建项目草稿时,读被控端**当前 New Maker
  // 草稿**在该 vendor 的完整选择(model/effort/fast/permission/source),1:1 seed 控制端草稿。
  // 数据真相在被控端(其 renderer 草稿),无 sender 依赖、无本机副作用 → 准入。老被控端无此 handler
  // → 控制端收 CHANNEL_NOT_ALLOWED → 回退被控端 capabilities 默认。
  "maker:get-new-maker-defaults",
  "maker:model-favorites:get",
  "maker:model-favorites:apply",
  // 协同创建 Worker 的角色清单与每个角色的记忆(任务文字、权限、模型路线):真相在被控端当前账号,
  // 手机与远程控制的电脑只读写这一份。get 读被控端 renderer 镜像给 main 的快照;apply 只接受
  // 「记下一次创建 / 移除一个角色」两种操作,由被控端转给自身 renderer 写回真源(无 sender 依赖、
  // 无本机 UI 副作用)。老被控端无此 handler → 控制端收 CHANNEL_NOT_ALLOWED → 只显示内置角色、不记忆。
  "maker:worker-roles:get",
  "maker:worker-roles:apply",
  // device-link 草稿「每个模型 effort/fast」写穿(控制端 → 被控端):控制端在远程项目草稿里改
  // 选中 / 非选中模型的 effort/fast 时通知被控端,被控端调它原来的本地 setter(setEffortForModel /
  // setFastModeForModel)写真实草稿;被控端 newMakerDraft 变更自动经既有 maker:sync-new-maker-draft
  // re-mirror 回 main 并广播。被控端转发给自身 renderer 执行(无 sender 依赖、无本机副作用)。
  // 老被控端无 handler → CHANNEL_NOT_ALLOWED → 控制端吞掉,退回一次性 pull 行为。
  "maker:apply-new-maker-draft-pref",
  // device-link 草稿「新建会话默认启用 worktree」写穿(控制端 → 被控端):worktree 勾选记忆是
  // 被控端 newMakerDraft 的 vendor 无关根字段,「这台工作端新建会话是否默认进 worktree」的真相
  // 在被控端。被控端 handler 校验布尔后转发给自身 renderer 写真实草稿(无 sender 依赖、无本机
  // UI 副作用);回读经 maker:get-new-maker-defaults + NEW_MAKER_DRAFT_CHANGED 回流。
  // 老被控端无 handler → CHANNEL_NOT_ALLOWED → 控制端吞掉降级(勾选仅本次草稿生效)。
  "maker:apply-new-maker-worktree-pref",
  // device-link 新建 worktree 源分支镜像:branch 选择属于被控端 canonical baseRepo,
  // 控制端先按 repo 拉取、显式选择时写穿，被控端返回/广播带 revision 的权威 snapshot。
  // GET 只读 main 内存镜像；APPLY 只更新该 repo 的 future-session 偏好，不执行 git/fs。
  "maker:get-new-maker-worktree-branch-pref",
  "maker:apply-new-maker-worktree-branch-pref",
  // 被控端侧栏项目顺序(显示偏好,真相在被控端 Main)。GET 只读;APPLY 写被控端
  // owner 作用域快照。不用 `:set` 后缀(全局设置写禁模式)。老被控端无 handler
  // → CHANNEL_NOT_ALLOWED → 控制端吞掉,回退本机/按时间。
  "sidebar-settings:get-project-order",
  "sidebar-settings:apply-project-order",
  // Host-owned project names are read-only on controllers. Local overrides and write channels stay local.
  "sidebar-settings:get-project-aliases",
  "sidebar-settings:set-project-info",
  "sidebar-settings:get-project-icon-image",
  "sidebar-settings:get-project-auto-icon",
  // 模型供应商目录(只读):远程会话的模型选择器据此 1:1 镜像被控端的「供应商+模型」结构。
  // 被控端 dispatch 在返回前剥离 routing 等执行字段(见 device-link/dispatch.ts),只回显示用字段。
  "maker:provider:list",
  // 供应商分享(只读):被控电脑收到的、别人分享给它的供应商目录(经被控电脑代读，手机读不到
  // 另一个账号的电脑)。只回显示用字段，供手机模型列表的远程供应商区域使用。
  "maker:provider-share:received-catalogs",
  // PROVIDER_SHARE_RECEIVED_CATALOGS_CHANNEL
  "maker:model-catalog:read",
  // Same-account task-host discovery + fixed read-only catalog/readiness operations.
  // Git safety 设置(只读):远程 Codex Rewind 入口必须按被控端是否会创建 safety snapshot
  // 决定显隐。SET/RESET 不放行,控制端不能改被控端全局偏好。
  "maker:git-safety:get",
  // 会话标题旁的 Git / GitHub 上下文(分支、PR 引用与实时状态)必须在被控端查询,
  // 因为控制端本地没有远端 session 的 DB、工作目录或 gh 登录态。
  "git-context:get-for-session",
  "git-context:pr-refs:list",
  "git-context:pr-refs:manage",
  "git-context:pr-status",
  "git-context:mr-status",
  "git-context:github-read",
  // —— 通用远程资源面——
  // 固定的 manifest / list / get / invoke 入口。业务模块只在被控端 provider
  // registry 注册资源与动作，后续新增模块或动作不再扩张 device-link channel 表。
  ...REMOTE_RESOURCE_CHANNELS,
  "maker:settings:navigate",
  // —— 读模型(被控端本地 DB 是数据真相)——
  "local-db:sessions:list",
  "local-db:task-tags:execute",
  "local-db:sessions:get",
  // Bounded metadata reconciliation. Old hosts reject this; controllers fall back to GET.
  "local-db:sessions:get-many",
  // Read-only indexed task search for the remote Composer @ palette and the
  // controller sidebar task search. Older controlled clients reject this
  // channel and the controller falls back to the bounded legacy sessions:list
  // projection.
  "local-db:conversations:search",
  DL_HISTORY_MESSAGES_CHANNEL,
  DL_HISTORY_QUERY_CHANNEL,
  "local-db:messages:list",
  // Read-only visible history and recoverable work ranges; same session authorization as list.
  "local-db:messages:view",
  "local-db:messages:work-details",
  "local-db:messages:view-intent",
  // 会话内搜索跳转定位(loadAroundMessage):只读,与 messages:list 同安全级。
  "local-db:messages:around",
  // 以 message clientId 定位上下文,供移动端轻量跳转 / fork 来源定位；只读,与 messages:around 同安全级。
  "local-db:messages:around-client-id",
  // 订阅形态会话「本会话价值」历史汇总(assistant agent_meta 估算值求和):只读聚合,
  // 无 sender 依赖、无副作用,与 messages:list 同安全级。控制端底部 $ chip 的历史初值
  // 必须查被控端(查本机是空库恒 0);老被控端无此 channel → CHANNEL_NOT_ALLOWED →
  // 控制端吞错,仅靠已加载消息 + 实时 turn-cost 推送呈现部分值。
  "local-db:messages:estimatedSessionValue",
  "local-db:recent-workdirs:list",
  // Host-owned project display names. No remote mutation of viewer preferences.
  "local-db:project-aliases:list",
  // 窄口径写:从被控端「最近项目」列表移除一条(专用 handler,path 归一后按主键删,
  // 幂等,不动 sessions / 磁盘)。控制端项目选择器的删除入口与本机语义对等;
  // 老被控端无此 handler → CHANNEL_NOT_ALLOWED → 控制端隐藏/忽略删除能力即可。
  "local-db:recent-workdirs:remove",
  // 窄口径元数据写:仅 status / title / pinnedAt(归档/删除/恢复/重命名/置顶)。专用
  // handler、白名单字段、不是裸 update(update 写任意字段、不放行)。支撑远程删/归档/改名/置顶对等。
  "local-db:sessions:patch-meta",
  "local-db:sessions:project-archive",
  // Atomic empty-task cleanup; older hosts reject the channel without deleting anything.
  "local-db:sessions:discard-unused",
  // 只读:「疑似中断」(startedAt > endedAt)的 active 会话 id(错误红点数据源)。
  // 与 sessions:list 同安全级。
  "local-db:sessions:interrupted-pending",
  // 窄口径写:中断提示的「继续/忽略」—— 仅写 sessions.last_turn_ended_at = now
  // (专用 handler,单字段幂等,不是裸 update)。远程会话的确认必须落被控端 DB,
  // 否则重开会话提示复活。老被控端无此 handler → CHANNEL_NOT_ALLOWED → 控制端
  // 吞错退化为本视图内存隐藏。
  "local-db:sessions:ack-interrupted",
  // 窄口径写:error-tail-banner 的「关闭/忽略」——仅把 role='error' 行的 content
  // merge dismissed:true(handler 内校验 role,原字段保留,不是裸 updateContent,
  // updateContent 本身不放行)。远程会话的忽略必须落被控端 DB,否则重连/重拉后
  // 红条复活。老被控端无此 handler → CHANNEL_NOT_ALLOWED → 控制端吞错退化为
  // 本视图内存隐藏。
  "local-db:messages:dismiss-error",
  // 消息菜单单条内容删除:在被控端清旧原生上下文并写 context rebuild handoff。
  "maker:message:delete",
  // 订阅控制帧(push 驱动):被控端 dispatch 拦截执行,不落到 ipcMain handler。
  // 列入 allowlist 作契约登记 + 老被控端不识别时回 CHANNEL_NOT_ALLOWED 供控制端探测能力(回退 poll)。
  DL_SUBSCRIBE_CHANNEL,
  DL_UNSUBSCRIBE_CHANNEL,
  // 入方向媒体取件(被控端 dispatch 拦截执行,不落 ipcMain handler;契约登记 + 能力探测)。
  DL_MEDIA_FETCH_CHANNEL,
  FILE_PEER_CHANNEL,
  TASK_MIGRATION_CHANNEL,
  // 新电脑设置(docs/product-rules/new-device-setup-migration.md):同账号新电脑读取这台电脑的
  // 非秘密配置快照(只读，被控端 dispatch 拦截执行)。不含密钥、OAuth、IM 凭证、登录与系统授权，
  // 不写被控端任何状态；共享任务访客与供应商分享受邀者在 dispatch 再拒一次。老版本无 handler →
  // CHANNEL_NOT_ALLOWED，新电脑提示更新那台电脑。
  SETUP_SNAPSHOT_CHANNEL,
  // 新电脑设置的密钥与 SSH 一步(同一规则页):新电脑请求复制指定连接的密钥、为它的新 SSH 公钥
  // 在这台电脑能连上的服务器上授权。被控端必须由人在本机确认(显示请求电脑、逐项名称与校验码)
  // 后才执行;密钥只以本次请求的临时公钥加密返回。OAuth 登录与私钥不经此通道。同样只给同账号电脑。
  SETUP_TRANSFER_CHANNEL,
  // 远程切换连接方式(docs/product-rules/agent-net.md「远程切换其他电脑的连接方式」,2026-11-12 用户确认):
  // 同账号电脑问这台电脑能不能打开 Agent-Net,并请它打开 / 关闭自己的「Agent-Net (Beta)」开关。
  // 开了远程控制的电脑本来就能被远程跑 Agent,不多给权限;「仅使用 Agent-Net」从不远程改。被控端 dispatch
  // 拦截执行，只给同账号电脑(共享任务访客与供应商分享受邀者再拒一次)。打开后必须在期限内经 Agent-Net
  // 收到同一发起端的确认，否则被控端自己退回。老版本无 handler → CHANNEL_NOT_ALLOWED,发起端显示需要更新。
  AGENT_NET_SWITCH_CHANNEL,
  // 远程 Agent(被控端 dispatch 拦截执行，不落 ipcMain handler)：在被控端用它自己的登录与
  // 供应商运行 Agent，文件、命令与 Cindy 工具回到控制端执行。准入同 fs:list-dir 的论证：
  // 同账号 + 被控端显式打开远程控制时，控制端本就能驱动被控端的 Agent；不进共享任务白名单。
  REMOTE_AGENT_CHANNEL,
  // 供应商组(被控端 dispatch 拦截执行，不落 ipcMain handler)：同账号电脑问组所在电脑该用组里哪台、
  // 报告运行中的任务与需要冷却的电脑。只给同账号，分享受邀者与共享任务访客在 dispatch 再拒一次。
  PROVIDER_GROUP_REMOTE_CHANNEL,
  // 出方向语音转写(被控端 dispatch 拦截执行,不落 ipcMain handler;复用被控端 ASR 配置)。
  DL_VOICE_TRANSCRIBE_CHANNEL,
  // 临时 voice credential 同步(被控端 dispatch 拦截执行,不落 ipcMain handler;禁止泛化)。
  DL_VOICE_CREDENTIAL_SYNC_CHANNEL,
  // voice dictionary learning evidence 回写(被控端 dispatch 拦截执行,不落 ipcMain handler)。
  DL_VOICE_DICTIONARY_LEARNING_CHANNEL,
  // 手机拉取被控桌面的词典只读快照(被控端 dispatch 拦截执行,不落 ipcMain handler;
  // 老被控端不识别时回 CHANNEL_NOT_ALLOWED,手机据此回退到「无词典」而不是报错)。
  DL_VOICE_DICTIONARY_GET_CHANNEL
];
var EXTENDED_INVOKE_CHANNELS = [
  // —— Scheduler(读 + 改 schedule 都在被控端执行才有意义)——
  "maker:schedule:list",
  "maker:schedule:get",
  "maker:schedule:create",
  "maker:schedule:update",
  "maker:schedule:delete",
  "maker:schedule:pause",
  "maker:schedule:resume",
  "maker:schedule:run-now",
  "maker:schedule:list-runs",
  "maker:schedule:list-sidebar-index-runs",
  "maker:schedule:list-cost-summaries",
  "maker:schedule:delete-run",
  "maker:schedule:get-runtime-state",
  "maker:schedule:get-inflight-count",
  "maker:schedule:get-unread-count",
  "maker:schedule:mark-run-read",
  "maker:schedule:mark-all-runs-read",
  "maker:schedule:mark-schedule-runs-read",
  "maker:schedule:list-templates",
  "maker:schedule:create-from-template",
  // script 任务能力选择器的可用性探测:纯只读查询,意识状态在被控端才有意义
  "maker:schedule:script-capability-status",
  // Status only: webhook-set-secret carries a credential and webhook-rotate-url replaces the
  // address; both stay on the computer that runs the schedule.
  "maker:schedule:webhook-status",
  "maker:schedule:webhook-receiver",
  // 同账号查看和释放云端地址；不携带密钥、不执行任务，不要求旧设备在线。
  "maker:schedule:webhook-account",
  "maker:schedule:webhook-release",
  "maker:schedule:webhook-restore",
  // —— 会话未读已读回执(控制端真实展示会话内容后,把被控端的会话未读态清掉)——
  // 准入:会话粒度状态操作(与 mark-run-read 同类),无 event.sender 依赖、无 shell/UI
  // 副作用;语义在被控端执行才正确(灵动岛 / Dock 角标 / 侧栏红绿点的未读真相都在被控端
  // main)。老被控端无此 channel → CHANNEL_NOT_ALLOWED → 控制端吞掉降级(仅本地清点)。
  "notification:clear-session-attention",
  // Completed-card action, guarded by an owner-issued token before any mutation.
  // Old hosts reject this channel; callers must not fall back to unguarded writes.
  "agent-island:completion-action",
  // —— Project automation ——
  "maker:project-automation:reconcile",
  "maker:project-automation:pending-imports",
  "maker:project-automation:list-consents",
  "maker:project-automation:revoke-consent",
  "maker:project-automation:upsert-schedule",
  "maker:project-automation:remove-schedule",
  // —— Orca 协同(Lead 控多 Worker;在被控端进程内编排)——
  "maker:worker:create",
  "maker:worker:dispatch-ui-assignment",
  "maker:worker:list",
  "maker:worker:switch-focus",
  "maker:worker:idle",
  "maker:worker:acknowledge-done",
  "maker:worker:archive",
  "maker:worker:update",
  "maker:team:end",
  "maker:session:enable-orca",
  "maker:session:disable-orca",
  "maker:mark-orca-role",
  "maker:collaboration-settings:get",
  "local-db:orca-workflows:get-by-lead",
  "local-db:orca-workflows:get-by-worker-session",
  "local-db:orca-workflows:list-workers-by-lead",
  // 协同远端 Worker：本机作为运行设备，承接另一台电脑上 Lead 派来的 Worker 任务。
  // 准入同 maker:create-session：同账号 + 本机开启远程控制时控制端本就能在这里建任务；
  // 业务 handler 不依赖 sender、无本机 UI 副作用；来源电脑取 server 盖章的 src。
  // 老版本无 handler → CHANNEL_NOT_ALLOWED，控制端提示更新而不回退普通建任务。
  ORCA_REMOTE_WORKER_CAPS_CHANNEL,
  ORCA_REMOTE_WORKER_BRIDGE_CHANNEL,
  ORCA_REMOTE_WORKER_MODELS_CHANNEL,
  ORCA_REMOTE_WORKER_OPEN_CHANNEL,
  ORCA_REMOTE_WORKER_RELEASE_CHANNEL,
  // 远程控制 Lead 所在电脑时，读取那台视角下可选的运行设备(只读，真相在被控端)。
  ORCA_EXECUTION_DEVICES_CHANNEL,
  // 云端伙伴：交出伙伴前探测目标电脑是否支持接手(只读常量，无 sender 依赖、无本机 UI 副作用)。
  // 老版本无 handler → CHANNEL_NOT_ALLOWED，交出方拒绝该目标。
  // 这台电脑此刻的资源情况(只读，真相在被控端，无 sender 依赖、无 UI 副作用)。不进 sharedTask 访客白名单；
  // 老版本无 handler → CHANNEL_NOT_ALLOWED，控制端显示需要更新。
  MACHINE_STATUS_CHANNEL,
  COMPANION_CLOUD_CAPS_CHANNEL,
  // 插件「查看伙伴」跨电脑读取(只读)：主力电脑返回本机可见伙伴的插件视图(状态、工作阶段、当前步骤、
  // 待处理请求标题、最新回复)。同账号且主力电脑开启远程控制时，控制端本就能经 sessions / messages 通道读到这些
  // 对话内容，此处不扩大可见范围；handler 不依赖 sender、无本机 UI 副作用，不进 sharedTask 访客白名单。
  // 老版本无 handler → CHANNEL_NOT_ALLOWED，查看端退回伙伴列表里的状态。
  COMPANION_LIVE_CHANNEL,
  // 云端伙伴：在任一台电脑上更换伙伴的主力电脑。只读读取主力电脑视角的可接手电脑，以及请主力电脑
  // 交出伙伴(写)。准入同本机伙伴设置的「主力电脑」一行：同账号 + 主力电脑开启远程控制时控制端本就
  // 能远程改这个伙伴；交出走被控端同一业务流程(同步、忙碌检查、比较后改主力电脑)，handler 不依赖
  // sender、无本机 UI 副作用。仅同账号远控，不进 sharedTask 访客白名单。老版本无 handler →
  // CHANNEL_NOT_ALLOWED；控制端按 caps 版本隐藏入口。
  COMPANION_CLOUD_TARGETS_CHANNEL,
  COMPANION_CLOUD_HAND_OVER_CHANNEL,
  // 云端伙伴：请保留的那个 Cindy 所在电脑合并其他 Cindy（写；同账号远控，准入同上，业务 handler 只在
  // 本机运行保留的那个 Cindy 时执行）。合并前请各来源 Cindy 的主力电脑先同步（写，只上传、不改主力电脑）。
  COMPANION_CLOUD_MERGE_CHANNEL,
  COMPANION_CLOUD_FLUSH_CHANNEL,
  // —— Rewind / Fork / Title / Context ——
  "maker:rewind:preview",
  "maker:rewind:commit",
  // Shared action via dispatch injection; local IPC retains its trusted-renderer guard.
  "maker:turn-change-set:apply",
  "maker:fork",
  // Independent history branch on the task's host; same authority as fork.
  "maker:side-chat:v1",
  "maker:side-chat:list:v1",
  "maker:fork-strip-encrypted",
  "maker:generate-title",
  // 重命名输入框 Magic 按钮:被控端读自己 DB 里的最新对话素材、用自己的 provider 凭证
  // 重生成标题(与 generate-title 同一 oneShot 通道)。老被控端无此 channel →
  // CHANNEL_NOT_ALLOWED → 控制端按生成失败提示。
  "maker:regenerate-title",
  // 输入框推荐提示词：在被控端读取会话素材并使用被控端模型凭证生成。
  "maker:predict-prompt",
  "maker:get-context-usage",
  // workflow 逐 agent 进度树(只读):handler 纯 fs 读 Claude Code workflow 记录文件,
  // 无 event.sender 依赖、无副作用;记录文件真相在被控端 HOME(控制端本机读必落空)。
  // 老被控端无此 channel → CHANNEL_NOT_ALLOWED → 控制端降级为无数据(回退 workflow 级
  // 卡片)。不进 INVOKE_TIMEOUT_OVERRIDES_MS:读小 JSON,默认 30s 足够。
  "maker:get-workflow-progress",
  // 后台命令输出尾部(只读):入参 (sessionId, taskId),handler 按被控端活跃会话的
  // 后台任务登记解析 SDK `.output` 路径并只读末尾一段,控制端无法指定路径;
  // 无 event.sender 依赖、无副作用;输出文件真相在被控端(控制端本机读必落空)。
  // 老被控端无此 channel → CHANNEL_NOT_ALLOWED → 控制端不显示「最近输出」。
  "maker:background-task:output-tail",
  // 会话仍在运行的后台任务快照(只读):handler 只查活跃会话内存句柄的任务列表,
  // 无 event.sender 依赖、无副作用;任务真身在被控端(控制端 main 无该会话 handle,
  // 本机查必空)。后台任务面板挂载水合用。老被控端无此 channel → CHANNEL_NOT_ALLOWED
  // → 控制端降级空表(面板退化为事件流 + 消息扫描两源)。
  "maker:session-background-tasks:list",
  "maker:session-background-activity",
  // 后台任务停止(写):单个任务精确停止 / 会话级「全部停止」。handler 只按 sessionId
  // (+ taskId)操作被控端活跃会话,无 event.sender 依赖、无本机 UI 副作用;任务真身在
  // 被控端,控制端本机调用只会假成功。仅同账号远控,不进 sharedTask 访客白名单。
  // 老被控端无此 channel → CHANNEL_NOT_ALLOWED → 控制端提示升级被控端。
  "maker:agent-task:stop",
  "maker:session-background-tasks:stop",
  // Durable PI Subagent truth and process handles live on the data-owning device.
  // Reads and exact controls must execute there; the controller must never fall
  // back to its own pi-agent-home for a remote task.
  "local-db:subagent-runs:list",
  "local-db:subagent-runs:detail",
  "local-db:subagent-runs:transcript",
  "maker:pi-subagent:control",
  // —— Goal(目标模式;goal 状态机在被控端 GoalController 执行才有意义)——
  "maker:goal:set",
  "maker:goal:clear",
  "maker:goal:get-status",
  "maker:goal:pause",
  "maker:goal:resume",
  "maker:goal:update",
  // —— Agent 状态 / 用量(只读)——
  "maker:agent:status",
  "maker:agent:binary-version",
  "maker:auth:get-state",
  "maker:usage:today",
  "maker:usage:account",
  // Codex app-server 官方控制面:额度/reset 次数读取 + 经 desktop 账号绑定 offer 的
  // 人工 reset。mutation 不接收 creditId,不能泛化成任意账号/凭证控制入口。
  "maker:usage:codex-rate-limits",
  // Owner-only native subscription profile management; no credentials cross this channel.
  "maker:subscription-accounts",
  "maker:subscription-pool:quota",
  "maker:usage:codex-rate-limit-reset",
  "maker:usage:codex-reset-auto-use",
  // 桌面小组件快照（只读，被控端 dispatch 拦截；准入同上方用量只读通道）。
  DL_USAGE_WIDGET_SNAPSHOT_CHANNEL,
  // Claude 订阅账号余量快照(只读,cached-first):控制端远程会话状态栏 chip 显示
  // 被控端订阅的 5h/周/分模型窗口剩余(数据真相在被控端 —— turn 在被控端消耗其
  // 订阅额度)。快照只含利用率百分比、reset 时间与账号归属指纹(单向 scrypt 哈希,
  // 与本机 renderer 收到的广播 payload 同形),不含凭证材料。无 sender 依赖、无副
  // 作用;老被控端无此 channel → CHANNEL_NOT_ALLOWED → 控制端降级为原「仅会话
  // 金额」占位显示。
  "maker:usage:claude-subscription",
  // xAI(SuperGrok)订阅周用量快照(只读):与 claude-subscription 同定位。该 channel
  // 的 ipcMain handler 挂了 assertTrustedSender(合成 event 必然不可信,那道闸不为
  // 远程放宽)—— 与 device-link:telegram:* 同先例,由被控端 dispatch 在通用 dispatch
  // 前拦截、直读 usage reader,不进 ipcMain。列入 allowlist 作契约登记 + 老被控端
  // CHANNEL_NOT_ALLOWED 供控制端探测降级。
  "maker:usage:xai-subscription",
  // Same-account read-only Kimi quota; no secrets, arbitrary endpoints, shared-task or share guests.
  // Old hosts reject the channel; callers never fall back to their local account.
  "maker:usage:kimi-coding",
  "maker:usage:opencode-go",
  // cc 默认路由会话的生效计费路由观察值(只读,'gateway' | 'subscription' | null):
  // 控制端远程会话据此判定订阅 / 网关显示形态 —— 路由真值在被控端 proxy 的按请求
  // 观察 registry 里,控制端拿本机凭证状态重算必然张冠李戴。入参 sessionId,无
  // sender 依赖、无副作用;老被控端 CHANNEL_NOT_ALLOWED → 控制端对默认路由远程
  // 会话维持「仅会话金额」占位(与旧行为一致)。
  "maker:claude-session-route:get",
  // 模型单价表(只读,main 侧 Model Access model-groups 投影缓存):控制端模型选择器展示
  // 被控端视角的单价(与被控端桌面 tooltip 同源)。无 sender 依赖、无副作用;老被控端无此 channel
  // → CHANNEL_NOT_ALLOWED → 控制端隐藏价格(与桌面「无价不显示」口径一致)。
  "maker:usage:model-pricing",
  // 用量历史跨设备合并(只读):同账号另一台电脑读取被控端 daily_spend / daily_model_usage
  // 原始行,合并进它自己的「所有设备」用量历史。数据真相在被控端;只含按天 × 模型聚合的
  // token 与金额,不含会话、消息或凭证。入参仅可选 sinceDay(YYYY-MM-DD),无 sender 依赖、
  // 无副作用;响应 gzip 编码,超帧预算回结构化 oversize。老被控端无此 channel →
  // CHANNEL_NOT_ALLOWED → 控制端把该设备标为「版本过旧」,不影响其它设备。
  "maker:usage:device-rows",
  // 网关 API key **presence-only** 探测:只回 { present: boolean },不回、也永不扩展为读取
  // 密钥材料 —— 这是「账号与密钥永不放行」大类下的窄口径例外(同 DL_VOICE_CREDENTIAL_SYNC
  // 的例外定位,禁止泛化)。用途:控制端模型选择器判断折扣版(codex/)是否该置灰,判定依据
  // 在被控端(key 存被控端 safeStorage、请求也从被控端发)。老被控端无此 channel →
  // CHANNEL_NOT_ALLOWED → 控制端按 unknown 处理(不置灰)。
  "maker:api-key:present",
  // —— Memory 读(写全局设置不放行)——
  // Teammate directory: handlers explicitly recognize the authorized device-link
  // context and return only identity/status/canonical task, without local paths,
  // memory, prompts, configuration, or native UI/file mutations.
  "local-db:bots:list",
  "local-db:bots:get",
  // Same-account opted-in controllers: private topic summaries and idempotent creation.
  // Existing Bot/root ownership and permission inheritance apply; no sender, UI or shell use.
  // Older hosts omit dmThreadsSupported; clients keep the canonical chat usable.
  "local-db:bots:dm-thread:list",
  "local-db:bots:dm-thread:ensure",
  // 伙伴自主跟进的工作台「一眼」：只读宿主内存状态表的投影（任务标题、等你的一句话摘要、
  // 分钟数、设备名），不含工作目录、提示词、工具入参或代输入值；handler 只放远程可见的伙伴。
  // 放行标准：① 只读 ② 同账号已授权控制端本就能经 maker:list-active / sessions:get-many 看到
  // 同样的任务标题与状态 ③ 没有任何写入或本机特权动作。设置读写（settings-*）不放行。
  "local-db:bots:autonomy:glance",
  // Same-account opted-in controllers read a companion's old task cards (read-only; cancel stays
  // for older controllers and answers UNSUPPORTED_CAPABILITY) and a participant-checked private
  // thread. No profile mutation.
  "maker:bot-delegations:list",
  "maker:bot-delegation:cancel",
  "maker:bot-direct-message-thread:get",
  "maker:memory:get",
  "maker:memory:get-settings",
  // —— 命令 / 技能 / at 资源 列举(只读)——
  "maker:list-desktop-commands",
  "maker:list-agent-commands",
  "maker:list-agent-skills",
  "maker:list-customizations",
  "maker:scan-at-resources",
  // —— 插件列表(只读)——
  // Public composer metadata only; no paths, secrets, lifecycle writes or shared guests.
  "ghosts:composer-list",
  "maker:plugins:list",
  // 单个插件的启停状态(只读)。与 maker:plugins:list 同类,差别只在它不跳过
  // HOSTED_ELSEWHERE 插件、且按 id 精确查。准入三条:handler 只读 settings + 项目
  // `.cindy/plugins.json`,不依赖 event.sender、无 UI/shell 副作用;插件启停真相在
  // 被控端(控制端拿被控端的路径查自己本机只会读到自己的用户级开关,判定可能与被控端
  // main 的 assertCollabProjectEnabled 相反 —— issue #1170 的「入口能点但走不完」)。
  // 用途:device-link 项目的协同入口按被控端的项目级 collab 开关置灰。老被控端无此
  // channel → CHANNEL_NOT_ALLOWED → 控制端 fail-closed 置灰并提示设备版本过旧。
  "maker:plugins:get-state",
  // —— 路径解析(被控端解析语义正确;新建会话选目录用)——
  "fs:resolve-path",
  "fs:resolve-path-batch",
  // —— 本机目录浏览(「添加远程项目」逐级选被控端项目目录用)——
  // 准入:只读目录枚举 + mkdir -p,**无**文件写/删/exec;且 device-link 已是同账号 +
  // remoteControlEnabled 显式 opt-in,控制端本就能在 workingDir 跑 agent(可执行任意命令),
  // 故列目录/建目录落在既有信任域内,不扩大攻击面。见 apps/desktop/src/main/fsBrowse/ipc.ts。
  "fs:list-dir",
  "fs:stat-path",
  "fs:mkdir-p",
  // —— 远程文件浏览(右侧栏 / doc 模式,读写增删 + 文件名索引 + 非流式搜索)——
  // 单聚合 channel:被控端专用 handler(见 apps/desktop/src/main/file-browser/device-op.ts),
  // 不复用依赖 event.sender 的既有 file-browser handler。准入:
  //  - workdir 参数先实时探测被控端本地可访问性,再结合 SSH session 归属解析
  //    唯一执行端点；本地 / SSH 或多 SSH 歧义时 fail closed。路径穿越在
  //    scanner 层拦(assertInsideWorkdir + realpath)。
  //  - device-link 已是同账号 + remoteControlEnabled 显式 opt-in,控制端本就能在
  //    workingDir 跑 agent(任意读写/exec),文件浏览不扩大攻击面(fs:list-dir 同款论证)。
  //  - readFile 结果超帧限前被控端预判回结构化 oversize,不裸炸 FRAME_TOO_LARGE。
  //  - 老被控端无此 channel → CHANNEL_NOT_ALLOWED,控制端渲染"设备版本过旧"占位。
  "file-browser:remote-op",
  // —— 远程 git 审查(右侧栏审查面板,只读)——
  // 单聚合 channel:被控端专用 handler(见 apps/desktop/src/main/git-review/device-op.ts),
  // 不复用本机 renderer 的 git-review:* handler。准入:
  //  - 只读 git 数据(status / diff / commit 列表 / 文件 diff / 图片与 Markdown 预览),
  //    **不放行任何写 op**(stage / discard / commit / push 不在被控端 handler 实现)。
  //  - 入参只有 sessionId + 结构化查询字段,不接受任何客户端路径:workdir 一律由被控端
  //    resolveReviewScope 从它自己的 session 记录解析,路径越界在 fsPathGuard 层拦。
  //  - device-link 已是同账号 + remoteControlEnabled 显式 opt-in,控制端本就能在
  //    workingDir 跑 agent(任意读/exec),只读 git 数据不扩大攻击面(fs:list-dir 同款论证)。
  //  - 响应超帧限前被控端预判:先 gzip,仍超回结构化 OVERSIZE,不裸炸 FRAME_TOO_LARGE。
  //  - 老被控端无此 channel → CHANNEL_NOT_ALLOWED,控制端渲染"设备版本过旧"占位。
  "git-review:remote-op",
  // —— 窄口径文本预览(消息附件 / tool 文件引用只读查看)——
  // 不是裸文件读:handler 要求绝对路径,复用系统目录 blocklist,10MB 上限,
  // 并用 reason 明确 oversize / not_found / forbidden。见 bootstrap-electron text-file:read-preview。
  "text-file:read-preview",
  // —— /learn 远程(learn-host 全流程在被控端:证据查它自己的 DB、staging 在它的
  // userData、skill 落它的 ~/.agents/skills;语义在被控端执行才正确)——
  // learn:apply 写被控端 skill 目录的越权论证:提案由被控端 staging 校验 + redaction
  // 双程扫描后生成,且 device-link 已是同账号 + remoteControlEnabled 显式 opt-in,
  // 控制端本就能经 agent 会话在被控端写文件,不扩大攻击面。入参只有 runId / 结构化
  // 请求体,不接受任何客户端路径(staging 路径全部由被控端生成)。
  "learn:start",
  "learn:list-runs",
  "learn:get-proposal-diff",
  "learn:apply",
  "learn:discard",
  "learn:cancel",
  // —— /cmd 远程(远程会话的 shell 命令在被控端 workingDir 执行才是正确语义)——
  // handler 对 cwd 走 remote-workdir-guard 实时可访问性探测,
  // 准入论证同 fs:list-dir:同账号 + 显式 opt-in 下控制端本就能驱动 agent 执行任意命令。
  "desktop-cmd:run",
  // —— Worktree(为被控端项目预建独立 git worktree;git/fs 语义在被控端执行才正确——
  // 控制端本机 git 探测被控端路径必然误报"不是 git 仓库")——
  // 准入:detect-cwd / list-branches / suggest-name 是只读 git 探测,无写副作用;
  // create 只在 baseRepo/.cindy-worktrees/<name> 下派生新目录(name 经被控端
  // validateWorktreeName 白名单校验,不接受任意路径),且 baseRepo 在被控端 dispatch
  // 层过 remote-workdir-guard 同款收敛(见 dispatch.ts PATH_GUARDED)。device-link
  // 已是同账号 + remoteControlEnabled 显式 opt-in,控制端本就能在项目目录跑 agent
  // (任意 exec),不扩大攻击面。removal-preview 只读、用于删除前警告；通用删除路径仍不放行。
  // discard-precreated 是唯一窄删除例外：常规收 sessionId + create 回包的精确 path；
  // 若手机在 create 回包前退出，则收其在 create 前已持久化、并与被控端 worktree
  // 元数据精确匹配的随机 recoveryKey。两路都重新核对 store 归属、无 DB/live
  // session、无 dirty/keep/live-ref 后才删；recoveryKey create/discard 另按 sessionId
  // 串行，且本口与 maker:create-session 共用 session 锁，专门补偿两步创建的失败窗口。
  // 老被控端无这些 channel → CHANNEL_NOT_ALLOWED → 控制端按对应能力降级。
  "worktree:detect-cwd",
  "worktree:list-branches",
  // Sync status is local-only; sync mutates only by explicit fetch + fast-forward.
  // sync-branch baseRepo also passes dispatch PATH_GUARDED_CHANNELS.
  "worktree:checkout",
  "worktree:branch-sync-status",
  "worktree:sync-branch",
  "worktree:suggest-name",
  "worktree:create",
  "worktree:discard-precreated",
  "worktree:cancel-precreated",
  "worktree:removal-preview",
  // —— 个人 Telegram bot 跨设备上下线(准入论证见上方 DL_TELEGRAM_* 常量注释)——
  // 两条都由被控端 dispatch 拦截执行, 不是 ipcMain handler。
  DL_TELEGRAM_STATUS_CHANNEL,
  DL_TELEGRAM_SET_ONLINE_CHANNEL
];
var REMOTE_INVOKE_ALLOWLIST = /* @__PURE__ */ new Set([
  // Same-account owner controls only; guest task dispatch has its own deny-by-default gate.
  "maker:shared-task",
  // Dedicated Host-only OAuth transaction. Args/replies are never forwarded to Renderer.
  "device-link:plugin-oauth:v3",
  "device-link:remote-desktop:v1",
  ...CORE_INVOKE_CHANNELS,
  ...EXTENDED_INVOKE_CHANNELS
]);
var INVOKE_TIMEOUT_OVERRIDES_MS = {
  // Evidence collection may include git diff and bounded artifact reads before
  // the host can acknowledge the newly-created Reviewer session.
  "maker:review:start": 9e4,
  // Two Git preflight/apply stages each allow 30s, plus snapshot and queue overhead.
  "maker:turn-change-set:apply": 9e4,
  [FILE_PEER_CHANNEL]: 3e4,
  // Capture renderer readiness + source enumeration + offer, then reply delivery.
  "device-link:remote-desktop:v1": REMOTE_DESKTOP_INVOKE_MS,
  // 被控端 CMD_TIMEOUT_MS(30s)+ CMD_KILL_GRACE_MS(5s)+ 5s 回程余量
  "desktop-cmd:run": 4e4,
  // 被控端 worktree:create 原生路径含 git worktree add(--no-checkout)+ 白名单文件选择性
  // checkout + .claude/.sivi 拷贝,数秒返回;仓库使用 Multibox 时同步克隆整个工作区与引擎
  // 缓存才返回(2026-11-16 实测 Unity 项目 28 万文件 67–88s,Multibox 文档同规模最慢 103s,
  // NTFS 复制模式更慢)。控制端在此期间显示创建中,给 5 分钟执行预算 + 回程余量。
  // 旧控制端仍按 60s 超时,超时后走既有预创建补偿;被控端执行不受此值影响。
  "worktree:create": 3e5,
  // 被控端 await agent.startSession:Codex app-server 冷启动 + thread/start 没有更短
  // deadline,机器高负载时实测 41.6s / 42.4s(2026-11-18)。默认 30s 会让控制端先超时:
  // 被控端照样建完任务,控制端却当失败处理,首条消息没发、用户重试又建一个新任务,
  // 旧的空任务永久滞留。给 2 分钟执行预算;被控端执行不受此值影响。
  "maker:create-session": 12e4,
  // User-triggered fetch (30s) plus local probes and process cleanup. Never replay.
  "worktree:sync-branch": 9e4,
  // 可能先等待同 sessionId 的晚到 create 释放互斥锁，再执行 git worktree remove。
  "worktree:discard-precreated": 6e4,
  "worktree:cancel-precreated": 6e4,
  // pi 手动压缩调 LLM 生成摘要,大上下文 + 网关排队可达分钟级(core 侧
  // PI_COMPACT_TIMEOUT_MS = 10min);默认 30s 隧道超时会截断远程压缩请求,
  // 用户在控制端看到的就是「无反馈失败」。给足执行预算 + 回程余量:
  // 被控端在请求穿过 relay 后才开始跑 PI_COMPACT_TIMEOUT_MS,控制端若只给相同
  // 10min,压缩恰好到预算上限时会先 INVOKE_TIMEOUT,被误判为「设备无响应」并
  // 可能触发 peer-link 恢复(codex P2)——同 desktop-cmd:run 模式加 1min 余量。
  "maker:compact-session": 11 * 6e4,
  // Persist drain + credentials refresh + 12s model request + return delivery.
  // Shared by desktop/mobile; only this invoke gets the longer wait, no peer reset.
  "maker:predict-prompt": 45e3,
  // 被控端先等 Lead history 最多 30s，再 resume/queue Worker；默认 30s 会与服务端
  // deadline 对撞，把边沿成功误报成 DEVICE_LINK_TIMEOUT。留出派发和回程余量。
  "maker:worker:dispatch-ui-assignment": 65e3,
  // 被控端要等目标任务的发送锁、必要时恢复 Agent（冷启动 / SSH 就绪）后才回执；默认 30s 会把
  // 已经送达的慢恢复报成「结果未知」，调用方重发就成了重复消息。
  [DL_SESSION_HANDOFF_CHANNEL]: 65e3,
  // 运行设备准备工作目录并启动 Worker 的 Agent，可能超过默认 30s。
  [ORCA_REMOTE_WORKER_OPEN_CHANNEL]: ORCA_REMOTE_WORKER_OPEN_TIMEOUT_MS,
  // 交出伙伴先把积压对话与全部资料传到服务器，再改主力电脑。
  [COMPANION_CLOUD_HAND_OVER_CHANNEL]: COMPANION_CLOUD_HAND_OVER_TIMEOUT_MS,
  [COMPANION_CLOUD_MERGE_CHANNEL]: COMPANION_CLOUD_MERGE_TIMEOUT_MS,
  [COMPANION_CLOUD_FLUSH_CHANNEL]: COMPANION_CLOUD_HAND_OVER_TIMEOUT_MS,
  // 设置快照要读插件、技能并等那台电脑的窗口回答界面偏好，可能超过默认 30s。
  [SETUP_SNAPSHOT_CHANNEL]: SETUP_SNAPSHOT_TIMEOUT_MS,
  // 要等那台电脑上的人确认(最多 2 分钟),再逐台连接 SSH 服务器授权新公钥。
  [SETUP_TRANSFER_CHANNEL]: SETUP_TRANSFER_TIMEOUT_MS,
  [AGENT_NET_SWITCH_CHANNEL]: AGENT_NET_SWITCH_TIMEOUT_MS,
  // listing tier 轻量 DB 读:毫秒级查询,12s 仍等不到只能是链路问题,快速失败喂给熔断器。
  // 12s 同时覆盖被控端冷启动 DB 迁移的常见时长(那类失败是快速返回的 DbClient not ready,
  // 不吃满超时),不会误伤首拉重试。
  "local-db:sessions:list": 12e3,
  "local-db:sessions:get": 12e3,
  "local-db:sessions:get-many": 12e3
};

// ../../packages/device-link/src/remoteClipboard.ts
var CLIPBOARD_CHUNK_CHARS = 64 * 1024;
var CLIPBOARD_MAX_CHARS = 32 * 1024 * 1024;

// ../../packages/device-link/src/remoteDesktop.ts
var DESKTOP_KEY_CODES = [
  ..."ABCDEFGHIJKLMNOPQRSTUVWXYZ".split("").map((key3) => `Key${key3}`),
  ..."0123456789".split("").map((key3) => `Digit${key3}`),
  ...Array.from({ length: 12 }, (_, i) => `F${i + 1}`),
  "Enter",
  "Escape",
  "Tab",
  "Space",
  "Backspace",
  "Delete",
  "Insert",
  "Home",
  "End",
  "PageUp",
  "PageDown",
  "ArrowUp",
  "ArrowDown",
  "ArrowLeft",
  "ArrowRight",
  "ShiftLeft",
  "ControlLeft",
  "AltLeft",
  "MetaLeft",
  "Minus",
  "Equal",
  "BracketLeft",
  "BracketRight",
  "Backslash",
  "Semicolon",
  "Quote",
  "Backquote",
  "Comma",
  "Period",
  "Slash"
];
var codes = new Set(DESKTOP_KEY_CODES);

// ../../packages/device-link/src/invokePolicy.ts
var BOT_GROUP_SEND_TIMEOUT_MS = 18e4;
var MCP_APP_OPEN_TIMEOUT_MS = 12e4;
var ACTION_INVOKE_TIMEOUTS_MS = [
  6 * 6e4,
  // Project cloning (five-minute Git budget plus profile persistence).
  BOT_GROUP_SEND_TIMEOUT_MS,
  MCP_APP_OPEN_TIMEOUT_MS,
  TASK_MIGRATION_ESTIMATE_TIMEOUT_MS,
  TASK_MIGRATION_RECEIVE_TIMEOUT_MS
];

// ../../packages/device-link/src/sessionMessageReuse.ts
var MAX_BYTES = 8 * 1024 * 1024;

// ../../packages/device-link/src/historyViewDelta.ts
var MAX_CHARS = 4 * 1024 * 1024;
var MAX_PAGE_CHARS = 2 * 1024 * 1024;

// ../../packages/device-link/src/transport.ts
var TRANSPORT_DELAYED_ACK_BYTES = 32 * 1024;
var MAX_TRANSPORT_CHUNK_BYTES = 128 * 1024;
var MAX_TRANSPORT_MESSAGE_BYTES = 4 * 1024 * 1024;
var MAX_TRANSPORT_REASSEMBLY_BYTES = 16 * 1024 * 1024;
var MAX_TRANSPORT_PENDING_BYTES = 16 * 1024 * 1024;
var MAX_TRANSPORT_WEBSOCKET_BUFFERED_BYTES = 8 * 1024 * 1024;
var TRANSPORT_RETRY_INTERVAL_MS = 2e3;
var TRANSPORT_MAX_RETRY_ATTEMPTS = 5;
var TRANSPORT_RETRY_PASS_BUDGET = 8;
var TRANSPORT_PENDING_PUSH_MAX_AGE_MS = 5 * 6e4;

// ../../packages/device-link/src/invokeDelta.ts
var MAX_BASE_CHARS = 4 * 1024 * 1024;
var MAX_BASE_CHARS_PER_PEER = MAX_BASE_CHARS / 2;

// ../../packages/device-link/src/invokeTransfer.ts
var INVOKE_TRANSFER_MIN_CHARS = 4 * 1024;
var INVOKE_TRANSFER_MAX_CHARS = 4 * 1024 * 1024;
var MAX_CACHE_KEY_CHARS = 4 * 1024;

// ../../packages/device-link/src/pushTransferDictionary.ts
var FRAGMENTS = [
  // 低频：其它 Agent 与投影标记。
  '"source":"pi"',
  '"source":"codex"',
  '"agentKind":"codex"',
  '"agentKind":"pi"',
  '"remoteContentTruncated":true',
  '"mobileToolResultProjected":true',
  "\\n[remote content truncated]",
  '"outputOmitted":true',
  '"inputSummary":"',
  '"processMedia":[',
  // 任务列表与状态推送。
  '{"sessionId":"","patch":{"title":"","status":"archived"}}',
  '{"sessionId":"","activity":{"status":"idle","isRunning":false,"updatedAt":,"unread":false,"title":"","lastMessagePreview":""}}',
  '{"sessionId":"","status":"idle"}',
  '{"sessionId":"","status":"running"}',
  '{"sessionId":""}',
  // 轮次收尾与用量。
  '{"type":"done","data":{"type":"result","subtype":"success","is_error":false,"duration_ms":,"num_turns":,"result":"","stop_reason":"end_turn","total_cost_usd":,"usage":{"input_tokens":,"output_tokens":,"cache_read_input_tokens":,"cache_creation_input_tokens":},"modelUsage":{},"requestUsage":{},"usageSegments":[],"usageSegmentsComplete":true},"source":"claude-code"}',
  '{"type":"status","data":{"status":"Done","tokenUsage":,"contextTokens":,"contextWindow":,"outputTokens":,"durationMs":,"tokenSpeed":,"generationReliable":false,"generationActive":false,"requestUsage":{"epoch":,"models":[{"model":"claude-","inputTokens":,"outputTokens":,"cacheReadTokens":,"cacheCreateTokens":}]},"isRunning":false},"source":"claude-code"}',
  '{"type":"usage","data":{"inputTokens":,"outputTokens":,"cacheReadTokens":,"cacheCreationTokens":,"contextTokens":,"contextWindow":}}',
  // 消息行（local-db:messages:created）。
  '{"sessionId":"","message":{"id":"","rowid":,"clientId":"","sessionId":"","role":"tool_result","content":"","toolUseId":"toolu_","agentMeta":{"uuid":"","sdkSessionId":"","model":"claude-","requestId":"req_"},"agentKind":"cc","createdAt":"2026-"}}',
  '"role":"user"',
  '"role":"thinking"',
  '"role":"tool_use","content":{"toolName":"","input":{}}',
  '"role":"assistant"',
  // 工具事件。
  '{"type":"tool_result_full","data":{"toolUseId":"toolu_","fullText":""}}',
  '{"type":"tool_result","data":{"summary":"","toolUseIds":["toolu_"]}}',
  '{"type":"tool_result","data":{"toolUseId":"toolu_","content":"","isError":false},"source":"claude-code"}',
  '"toolName":"TodoWrite","input":{"todos":[{"content":"","status":"pending","activeForm":""}]}',
  '"toolName":"Write","input":{"file_path":"","content":""}',
  '"toolName":"Edit","input":{"file_path":"","old_string":"","new_string":"","replace_all":false}',
  '"toolName":"Grep","input":{"pattern":"","path":"","output_mode":"content","-n":true}',
  '"toolName":"Read","input":{"file_path":""}',
  '{"type":"tool_use","data":{"toolUseId":"toolu_","toolName":"Bash","input":{"command":"","description":""}},"source":"claude-code"}',
  // 思考与正文增量（最常见，放在最后）。
  '{"type":"status","data":{"status":"Generating...","isRunning":true},"source":"claude-code"}',
  '{"type":"thinking","data":{"stage":"start","blockId":"thinking-","startedAt":}',
  '{"type":"thinking","data":{"stage":"final","blockId":"thinking-","text":"","durationMs":}',
  '{"type":"thinking","data":{"stage":"delta","blockId":"thinking-","text":""},"source":"claude-code"',
  '{"type":"text","data":{"text":"","isFinal":true},"source":"claude-code"',
  '{"sessionId":"","events":[{"sessionId":"","event":{"type":"text","data":{"text":"","isFinal":false},"source":"claude-code","agentMeta":{"uuid":"","sdkSessionId":"","model":"claude-","requestId":"req_"},"turnOrigin":{"kind":"user"},"turnAttemptToken":},"persistId":""}]}'
];
var PUSH_TRANSFER_DICTIONARY_V1 = FRAGMENTS.join("");
if (!/^[\x20-\x7e]*$/.test(PUSH_TRANSFER_DICTIONARY_V1)) {
  throw new Error("PUSH_TRANSFER_DICTIONARY_V1 must be printable ASCII");
}

// ../../packages/device-link/src/pushTransfer.ts
var PUSH_TRANSFER_MAX_BYTES = 512 * 1024;

// ../../packages/device-link/src/transportBacklog.ts
var BACKLOG_WARN_BYTES = 4 * 1024 * 1024;

// ../../packages/device-link/src/pluginSyncProtocol.ts
var PLUGIN_SYNC_MAX_BYTES = 64 * 1024;

// ../../packages/device-link/src/selfHostedRelayAuth.ts
var RELAY_FRAME_MAX_SKEW_MS = 10 * 60 * 1e3;
var KEY_32_PATTERN = /^[A-Za-z0-9_-]{43}$/;
var ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
var ALPHABET_INDEX = new Int16Array(128).fill(-1);
for (let i = 0; i < ALPHABET.length; i++) ALPHABET_INDEX[ALPHABET.charCodeAt(i)] = i;
function encodeBase64Url(bytes) {
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i];
    const b = bytes[i + 1];
    const c = bytes[i + 2];
    out += ALPHABET[a >> 2] + ALPHABET[(a & 3) << 4 | (b ?? 0) >> 4];
    if (b !== void 0) out += ALPHABET[(b & 15) << 2 | (c ?? 0) >> 6];
    if (c !== void 0) out += ALPHABET[c & 63];
  }
  return out;
}
function decodeBase64Url(value) {
  if (value.length % 4 === 1) return null;
  const out = new Uint8Array(Math.floor(value.length * 3 / 4));
  let bits = 0;
  let acc = 0;
  let index = 0;
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    const digit = code < 128 ? ALPHABET_INDEX[code] : -1;
    if (digit < 0) return null;
    acc = acc << 6 | digit;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[index++] = acc >> bits & 255;
    }
  }
  if ((acc & (1 << bits) - 1) !== 0) return null;
  return out;
}
function utf8Bytes(text2) {
  const out = [];
  for (let i = 0; i < text2.length; i++) {
    let code = text2.charCodeAt(i);
    if (code >= 55296 && code <= 56319 && i + 1 < text2.length) {
      const next = text2.charCodeAt(i + 1);
      if (next >= 56320 && next <= 57343) {
        code = 65536 + (code - 55296 << 10) + (next - 56320);
        i++;
      }
    }
    if (code >= 55296 && code <= 57343) code = 65533;
    if (code < 128) out.push(code);
    else if (code < 2048) out.push(192 | code >> 6, 128 | code & 63);
    else if (code < 65536) out.push(224 | code >> 12, 128 | code >> 6 & 63, 128 | code & 63);
    else out.push(240 | code >> 18, 128 | code >> 12 & 63, 128 | code >> 6 & 63, 128 | code & 63);
  }
  return Uint8Array.from(out);
}
function isRelayPublicKey(value) {
  return typeof value === "string" && KEY_32_PATTERN.test(value) && decodeBase64Url(value) !== null;
}

// ../../packages/device-link/src/directCapacity.ts
var DIRECT_LINK_IDLE_MS = 5 * 6e4;

// ../../packages/device-link/src/directNegotiation.ts
var DIRECT_LINK_MAX_SDP = 128 * 1024;

// ../../packages/device-link/src/directPath.ts
var DIRECT_PATH_HIGH_WATER_BYTES = 1024 * 1024;
var PROVIDER_SHARE_DIRECT_LEASE_MS = 30 * 6e4;
var DIRECT_PATH_SIGNALING_GRACE_MS = 30 * 6e4;

// ../../packages/device-link/src/client.ts
var PROVIDER_SHARE_SIGNAL_ROUTE_TTL_MS = 2 * 6e4;
var SOCKET_DATA_HIGH_WATER_BYTES = 512 * 1024;
var SOCKET_DATA_LOW_WATER_BYTES = 128 * 1024;
var SOCKET_CONTROL_RESERVE_BYTES = 64 * 1024;
var SOCKET_SEND_CREDIT_BYTES = 64 * 1024;
var RELIABLE_ACK_BATCH_BYTES = 256 * 1024;
var RELIABLE_RETRY_BYTES_PER_INTERVAL = 16 * 1024;
var MAX_LEGACY_INBOUND_BYTES = 16 * 1024 * 1024;
var DEFAULT_TIMING = {
  reconnectBaseMs: 1e3,
  reconnectMaxMs: 3e4,
  reconnectStableResetMs: 1e4,
  pingIntervalMs: 2e4,
  // 允许弱网在一个额外周期内恢复；真正无响应仍由连续 miss + 无入站流量判定。
  pongMissLimit: 3,
  requestTimeoutMs: 3e4,
  getTokenTimeoutMs: 15e3,
  handshakeTimeoutMs: 15e3,
  transportRetryIntervalMs: TRANSPORT_RETRY_INTERVAL_MS,
  transportMaxRetryAttempts: TRANSPORT_MAX_RETRY_ATTEMPTS,
  transportRetryPassBudget: TRANSPORT_RETRY_PASS_BUDGET,
  presenceRetryIntervalMs: 500,
  stalledLinkPendingMaxAgeMs: 6e4,
  congestionBackoffBaseMs: 5e3,
  congestionBackoffMaxMs: 3e4,
  congestionStableResetMs: 15 * 6e4
};

// ../../packages/device-link/src/attachmentOssRef.ts
var ATTACH_OSS_SCHEME = "cindy-oss-attach";
var LEGACY_ATTACH_OSS_SCHEME = "xdt-oss-attach";
var ATTACH_OSS_PREFIX = `${ATTACH_OSS_SCHEME}://m/`;
var LEGACY_ATTACH_OSS_PREFIX = `${LEGACY_ATTACH_OSS_SCHEME}://m/`;

// ../../packages/device-link/src/peerAttachment.ts
var OSS_ATTACHMENT_MAX_BYTES = 2 * 1024 ** 3;

// ../../packages/device-link/src/fileAccess.ts
var FILE_INLINE_MAX_BYTES = 64 * 1024;

// ../../packages/device-link/src/providerShareInvitation.ts
var PROVIDER_SHARE_LINK_TTL_MS = 5 * 6e4;

// ../../packages/device-link/src/metadataContinuity.ts
var PROVIDER_METADATA_TRUST_MS = 30 * 6e4;
var SNAPSHOT_CHARACTER_BUDGET = 8 * 1024 * 1024;

// ../../packages/device-link/src/selfHostedRelay.ts
var RELAY_APPS = /* @__PURE__ */ new Set(["cindy", "cindycn", "cindydev"]);
var MAX_LINK_LENGTH = 2048;
var JOIN_CODE_PATTERN = /^[A-Za-z0-9_-]{16,256}$/;
var PAIR_SECRET_PATTERN = /^[A-Za-z0-9_-]{43}$/;
var API_PREFIX = "/api/device-link";
var V2_CODE_PATTERN = /^[A-Za-z0-9_-]{32}$/;
var ACCOUNT_TAG_PATTERN = /^[A-Za-z0-9_-]{22}$/;
var UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
var OWNER_NAME_MAX = 64;
function ownerNameOf(value) {
  const name = value?.trim();
  return name && name.length <= OWNER_NAME_MAX ? name : null;
}
function normalizeRelayBaseUrl(value) {
  let url;
  try {
    url = new URL(value.trim());
  } catch {
    return null;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  if (url.username || url.password || url.search || url.hash || !url.hostname) return null;
  const pathname = url.pathname.replace(/\/+$/, "");
  if (pathname.startsWith(API_PREFIX)) return null;
  return `${url.protocol}//${url.host}${pathname}`;
}
function parseRelayJoinLink(value) {
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > MAX_LINK_LENGTH) return null;
  const match = /^(?:([a-z]+):\/\/relay|\/relay)\/join\/?\?(.*)$/i.exec(trimmed);
  if (!match) return null;
  if (match[1] && !RELAY_APPS.has(match[1].toLowerCase())) return null;
  const params = new URLSearchParams(match[2]);
  const rawBase = params.get("u");
  const code = params.get("c");
  const ownerPublicKey = params.get("o");
  const pairSecret = params.get("s");
  const agentNetCode = params.get("a");
  if (!rawBase || code !== null && !JOIN_CODE_PATTERN.test(code)) return null;
  if (!isRelayPublicKey(ownerPublicKey) || !pairSecret || !PAIR_SECRET_PATTERN.test(pairSecret)) return null;
  if (agentNetCode !== null && !V2_CODE_PATTERN.test(agentNetCode)) return null;
  const relayId = params.get("r");
  if (code === null && (agentNetCode === null || !relayId || !UUID_PATTERN.test(relayId))) return null;
  const ownerName = ownerNameOf(params.get("n"));
  const tenantCode = params.get("g");
  const ownerAccountTag = params.get("h");
  if (tenantCode === null !== (ownerAccountTag === null)) return null;
  if (tenantCode !== null && (!V2_CODE_PATTERN.test(tenantCode) || !ACCOUNT_TAG_PATTERN.test(ownerAccountTag))) return null;
  const baseUrl = normalizeRelayBaseUrl(rawBase);
  return baseUrl ? {
    baseUrl,
    ...code ? { code } : {},
    ownerPublicKey,
    pairSecret,
    ...agentNetCode ? { agentNetCode } : {},
    ...tenantCode && ownerAccountTag ? { tenantCode, ownerAccountTag } : {},
    ...ownerName ? { ownerName } : {},
    ...code === null && relayId ? { relayId } : {}
  } : null;
}

// ../../packages/device-link/src/relayAccountDirectory.ts
var RELAY_ACCOUNT_JOIN_TTL_MS = 10 * 60 * 1e3;
var RELAY_ACCOUNT_INVITE_WAIT_MS = 45 * 1e3;
var RELAY_ACCOUNT_ACK_WAIT_MS = 12 * 1e3;
var ID_PATTERN2 = /^[A-Za-z0-9._:-]{1,128}$/;
var RELAY_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
var MAX_ENTRIES = 32;
function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function text(value, max) {
  return typeof value === "string" && value.trim() && value.length <= max ? value : null;
}
function time(value) {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : null;
}
function parseOffer(ownerDeviceId, raw) {
  if (!ID_PATTERN2.test(ownerDeviceId) || !isRecord(raw)) return null;
  const ownerDeviceName = text(raw.ownerDeviceName, 128);
  const relayId = typeof raw.relayId === "string" && RELAY_ID_PATTERN.test(raw.relayId) ? raw.relayId : null;
  const name = text(raw.name, 64);
  const baseUrl = typeof raw.baseUrl === "string" ? normalizeRelayBaseUrl(raw.baseUrl) : null;
  const kind = raw.kind === "server" || raw.kind === "host" || raw.kind === "shared" ? raw.kind : null;
  const updatedAt = time(raw.updatedAt);
  if (!ownerDeviceName || !relayId || !name || !baseUrl || !kind || !updatedAt || !isRelayPublicKey(raw.ownerPublicKey)) return null;
  return {
    ownerDeviceId,
    ownerDeviceName,
    relayId,
    name,
    baseUrl,
    ownerPublicKey: raw.ownerPublicKey,
    kind,
    ...kind === "shared" ? { sharedBy: text(raw.sharedBy, 64) } : {},
    updatedAt
  };
}
function parseRelayAccountOffers(value) {
  const offers = isRecord(value) && value.v === 1 && isRecord(value.offers) ? value.offers : {};
  return Object.entries(offers).slice(0, MAX_ENTRIES).flatMap(([deviceId, raw]) => {
    const offer = parseOffer(deviceId, raw);
    return offer ? [offer] : [];
  });
}
function parseRequest(deviceId, raw) {
  if (!ID_PATTERN2.test(deviceId) || !isRecord(raw)) return null;
  const requestId = typeof raw.requestId === "string" && RELAY_ID_PATTERN.test(raw.requestId) ? raw.requestId : null;
  const deviceName = text(raw.deviceName, 128);
  const platform = text(raw.platform, 32);
  const relayId = typeof raw.relayId === "string" && RELAY_ID_PATTERN.test(raw.relayId) ? raw.relayId : null;
  const ownerDeviceId = typeof raw.ownerDeviceId === "string" && ID_PATTERN2.test(raw.ownerDeviceId) ? raw.ownerDeviceId : null;
  const createdAt = time(raw.createdAt);
  if (!requestId || !deviceName || !platform || !relayId || !ownerDeviceId || !createdAt || !isRelayPublicKey(raw.publicKey)) return null;
  return { requestId, deviceId, deviceName, platform, relayId, ownerDeviceId, publicKey: raw.publicKey, createdAt };
}
function parseInvite(raw) {
  if (!isRecord(raw)) return null;
  const requestId = typeof raw.requestId === "string" && RELAY_ID_PATTERN.test(raw.requestId) ? raw.requestId : null;
  const relayId = typeof raw.relayId === "string" && RELAY_ID_PATTERN.test(raw.relayId) ? raw.relayId : null;
  const expiresAt = time(raw.expiresAt);
  if (!requestId || !relayId || !expiresAt) return null;
  if (raw.error === "RELAY_UNAVAILABLE") return { requestId, relayId, error: raw.error, expiresAt };
  if (raw.pending === true && raw.link === void 0) return { requestId, relayId, pending: true, expiresAt };
  const link = typeof raw.link === "string" ? parseRelayJoinLink(raw.link) : null;
  return link ? { requestId, relayId, link: raw.link, expiresAt } : null;
}
function parseRelayAccountJoinBoard(value, now2) {
  const board = { requests: {}, invites: {} };
  if (!isRecord(value) || value.v !== 1) return board;
  const requests = isRecord(value.requests) ? Object.entries(value.requests).slice(0, MAX_ENTRIES) : [];
  for (const [deviceId, raw] of requests) {
    const request = parseRequest(deviceId, raw);
    if (request && request.createdAt + RELAY_ACCOUNT_JOIN_TTL_MS > now2) board.requests[deviceId] = request;
  }
  const invites = isRecord(value.invites) ? Object.entries(value.invites).slice(0, MAX_ENTRIES) : [];
  for (const [deviceId, raw] of invites) {
    const invite = ID_PATTERN2.test(deviceId) ? parseInvite(raw) : null;
    if (invite && invite.expiresAt > now2) board.invites[deviceId] = invite;
  }
  return board;
}
function serializeRelayAccountJoinBoard(board) {
  return { v: 1, requests: board.requests, invites: board.invites };
}

// ../../packages/device-link/src/pluginPages.ts
var PLUGIN_PAGE_MAX_BUNDLE_BYTES = 64 * 1024 * 1024;
var PLUGIN_PAGE_MAX_MESSAGE_BYTES = 48 * 1024;

// ../../packages/device-link/src/pluginOauth.ts
var PLUGIN_OAUTH_TTL_MS = 5 * 6e4;

// ../../packages/agent-net/src/portableBytes.ts
function fromBase64Url(text2) {
  const result = decodeBase64Url(text2);
  if (result === null) throw new Error("INVALID_BASE64URL");
  return result;
}
var toBase64Url = encodeBase64Url;
var utf8 = (text2) => typeof TextEncoder === "function" ? new TextEncoder().encode(text2) : utf8Bytes(text2);
function decodeUtf8(bytes) {
  if (typeof TextDecoder === "function") return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  const chunks = [], units = [];
  const continuation = (offset) => {
    const value = bytes[offset];
    if (value === void 0 || (value & 192) !== 128) throw new Error("INVALID_UTF8");
    return value & 63;
  };
  for (let at = 0; at < bytes.length; ) {
    const first = bytes[at++];
    let code;
    if (first < 128) code = first;
    else if (first >= 194 && first <= 223) {
      code = (first & 31) << 6 | continuation(at++);
    } else if (first >= 224 && first <= 239) {
      const second = continuation(at++), third = continuation(at++);
      code = (first & 15) << 12 | second << 6 | third;
      if (code < 2048 || code >= 55296 && code <= 57343) throw new Error("INVALID_UTF8");
    } else if (first >= 240 && first <= 244) {
      code = (first & 7) << 18 | continuation(at++) << 12 | continuation(at++) << 6 | continuation(at++);
      if (code < 65536 || code > 1114111) throw new Error("INVALID_UTF8");
    } else throw new Error("INVALID_UTF8");
    if (code <= 65535) units.push(code);
    else {
      code -= 65536;
      units.push(55296 | code >>> 10, 56320 | code & 1023);
    }
    if (units.length >= 4096) {
      chunks.push(String.fromCharCode(...units));
      units.length = 0;
    }
  }
  if (units.length) chunks.push(String.fromCharCode(...units));
  return chunks.join("");
}
var keyHex = (text2) => Array.from(fromBase64Url(text2), (byte) => byte.toString(16).padStart(2, "0")).join("");
function concatBytes(parts) {
  const result = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

// ../../packages/agent-net/src/nativeMedia.ts
function check(options, engine) {
  if (options.binding !== void 0 && !/^[\x21-\x7e]{1,256}$/.test(options.binding)) throw new Error("INVALID_MEDIA_BINDING");
  if (options.signal?.aborted) throw new Error("MEDIA_CANCELLED");
  options.assertCurrent?.();
  engine.assertCurrent?.();
}
function sessionValid(value, size) {
  return Number.isSafeInteger(value.id) && value.id > 0 && Number.isSafeInteger(value.size) && value.size >= 0 && value.size <= 2 * 1024 * 1024 * 1024 && (size === void 0 || value.size === size) && value.encryptedSize === MEDIA_ENCRYPTED_HEADER_BYTES + value.size + Math.ceil(value.size / MEDIA_PLAINTEXT_CHUNK_BYTES) * 16 && value.encryptedSize <= MAX_MEDIA_OBJECT_BYTES && /^[a-f0-9]{64}$/.test(value.headerSha256);
}
async function uploadNativeMedia(api, engine, recipient, recipientKey, size, read, options = {}) {
  check(options, engine);
  const session = await engine.command({ op: "mediaCreateUpload", recipientKey, size, ...options.binding ? { binding: options.binding } : {} });
  let id;
  try {
    check(options, engine);
    if (!sessionValid(session, size)) throw new Error("INVALID_MEDIA_SESSION");
    if (options.binding !== void 0 && session.binding !== options.binding) throw new Error("AGENT_NET_NATIVE_UPDATE_REQUIRED");
    const created = api.createMedia ? await api.createMedia(recipient, session.encryptedSize, options.signal) : await api.request("POST", "/media", { recipient, size: session.encryptedSize, chunkFormat: "binary-v1" }, { signal: options.signal });
    id = created.id;
    check(options, engine);
    if (!/^[a-f0-9-]{36}$/.test(id) || !Number.isSafeInteger(created.chunkBytes) || created.chunkBytes < MEDIA_PLAINTEXT_CHUNK_BYTES + 16 || created.chunkBytes > MAX_MEDIA_BINARY_CHUNK_BYTES) throw new Error("MEDIA_STREAM_UNSUPPORTED");
    let batch = [fromBase64Url(session.header)], batchBytes = MEDIA_ENCRYPTED_HEADER_BYTES, written = 0;
    const flush = async () => {
      check(options, engine);
      const response = await api.putMediaChunk(id, written, concatBytes(batch), options.signal);
      check(options, engine);
      written += batchBytes;
      if (response.received !== written) throw new Error("MEDIA_OFFSET_MISMATCH");
      batch = [];
      batchBytes = 0;
    };
    for (let offset = 0; offset < size; offset += MEDIA_PLAINTEXT_CHUNK_BYTES) {
      check(options, engine);
      const plain = await read(offset, Math.min(MEDIA_PLAINTEXT_CHUNK_BYTES, size - offset));
      check(options, engine);
      if (plain.length !== Math.min(MEDIA_PLAINTEXT_CHUNK_BYTES, size - offset)) throw new Error("MEDIA_SOURCE_CHANGED");
      const encoded = await engine.command({ op: "mediaEncrypt", id: session.id, data: toBase64Url(plain) });
      check(options, engine);
      const cipher = fromBase64Url(encoded);
      if (cipher.length !== plain.length + 16) throw new Error("INVALID_MEDIA_CHUNK");
      if (batchBytes + cipher.length > created.chunkBytes) await flush();
      batch.push(cipher);
      batchBytes += cipher.length;
      options.onProgress?.(Math.min(size, offset + plain.length), size);
    }
    if (batchBytes) await flush();
    if (written !== session.encryptedSize) throw new Error("MEDIA_SIZE_MISMATCH");
    const finished = await engine.command({ op: "mediaFinish", id: session.id });
    check(options, engine);
    if (!/^[a-f0-9]{64}$/.test(finished.sha256)) throw new Error("INVALID_MEDIA_HASH");
    return { id, sha256: finished.sha256, headerSha256: session.headerSha256 };
  } catch (error) {
    if (id) {
      const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 3e3);
      try {
        await api.request("DELETE", "/media/" + id, void 0, { signal: controller.signal });
      } catch {
      } finally {
        clearTimeout(timer);
      }
    }
    throw error;
  } finally {
    await engine.command({ op: "mediaClose", id: session.id }).catch(() => void 0);
  }
}
async function range(api, engine, id, start, end, total, options, progress) {
  check(options, engine);
  const consume = async (response, onByteProgress) => {
    check(options, engine);
    const match = /^bytes (\d+)-(\d+)\/(\d+)$/.exec(response.headers.get("content-range") ?? "");
    if (response.status !== 206 || !match || Number(match[1]) !== start || Number(match[2]) !== end || !Number.isSafeInteger(Number(match[3])) || Number(match[3]) > MAX_MEDIA_OBJECT_BYTES || total !== void 0 && Number(match[3]) !== total) {
      await response.body?.cancel();
      throw new Error("INVALID_MEDIA_RANGE");
    }
    const needed = end - start + 1, reader = response.body?.getReader?.();
    let bytes;
    if (reader) {
      bytes = new Uint8Array(needed);
      let received = 0;
      try {
        for (; ; ) {
          const chunk = await reader.read();
          check(options, engine);
          if (chunk.done) break;
          if (received + chunk.value.length > needed) throw new Error("INVALID_MEDIA_CHUNK");
          bytes.set(chunk.value, received);
          received += chunk.value.length;
          if (chunk.value.length) {
            onByteProgress?.(chunk.value.length);
            progress?.(received);
          }
        }
        if (received !== needed) throw new Error("MEDIA_INCOMPLETE");
      } finally {
        await reader.cancel().catch(() => void 0);
        reader.releaseLock();
      }
    } else {
      bytes = new Uint8Array(await response.arrayBuffer());
      check(options, engine);
    }
    if (bytes.length !== needed) throw new Error("MEDIA_INCOMPLETE");
    return { bytes, total: Number(match[3]) };
  };
  const requestRange = `bytes=${start}-${end}`;
  return api.withMediaResponse(id, requestRange, consume, options.signal);
}
async function openNativeMediaReader(api, engine, id, headerSha256, options = {}) {
  const currentApi = () => typeof api === "function" ? api() : api;
  const first = await range(currentApi(), engine, id, 0, MEDIA_ENCRYPTED_HEADER_BYTES - 1, void 0, options);
  const session = await engine.command({
    op: "mediaOpen",
    header: toBase64Url(first.bytes),
    headerSha256,
    ...options.binding ? { binding: options.binding } : {}
  });
  let closed = false;
  const blocks = /* @__PURE__ */ new Map();
  const close = async () => {
    if (closed) return;
    closed = true;
    for (const block of blocks.values()) block.fill(0);
    blocks.clear();
    await engine.command({ op: "mediaClose", id: session.id }).catch(() => void 0);
  };
  try {
    check(options, engine);
    if (!sessionValid(session) || session.encryptedSize !== first.total) throw new Error("INVALID_MEDIA_HEADER");
    if (options.binding !== void 0 && session.binding !== options.binding) throw new Error("AGENT_NET_NATIVE_UPDATE_REQUIRED");
    return { size: session.size, close, async read(start, requestedEnd, write, activity) {
      if (closed) throw new Error("MEDIA_CLOSED");
      check(options, engine);
      if (session.size === 0 && start === 0 && requestedEnd === -1) return { size: 0, start: 0, end: -1 };
      const end = Math.min(requestedEnd, session.size - 1);
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start || start >= session.size) throw new Error("INVALID_MEDIA_RANGE");
      activity?.("active");
      let received = 0;
      const readOptions = activity?.signal ? { ...options, signal: activity.signal } : options;
      for (let index = Math.floor(start / MEDIA_PLAINTEXT_CHUNK_BYTES); index <= Math.floor(end / MEDIA_PLAINTEXT_CHUNK_BYTES); index++) {
        const plainSize = Math.min(MEDIA_PLAINTEXT_CHUNK_BYTES, session.size - index * MEDIA_PLAINTEXT_CHUNK_BYTES), cipherStart = MEDIA_ENCRYPTED_HEADER_BYTES + index * (MEDIA_PLAINTEXT_CHUNK_BYTES + 16);
        let plain = blocks.get(index);
        if (!plain) {
          const encrypted = await range(
            currentApi(),
            engine,
            id,
            cipherStart,
            cipherStart + plainSize + 15,
            session.encryptedSize,
            readOptions,
            (bytes) => activity?.("active", received + bytes)
          );
          const decoded = await engine.command({ op: "mediaDecrypt", id: session.id, index, data: toBase64Url(encrypted.bytes) });
          check(options, engine);
          if (closed) throw new Error("MEDIA_CLOSED");
          plain = fromBase64Url(decoded);
          if (plain.length !== plainSize) throw new Error("INVALID_MEDIA_CHUNK");
          const old = blocks.get(index);
          if (old) old.fill(0);
          blocks.set(index, plain);
          while (blocks.size > 2) {
            const first2 = blocks.keys().next().value;
            blocks.get(first2).fill(0);
            blocks.delete(first2);
          }
        }
        received += plainSize + 16;
        activity?.("active", received);
        const from = Math.max(0, start - index * MEDIA_PLAINTEXT_CHUNK_BYTES), to = Math.min(plain.length, end - index * MEDIA_PLAINTEXT_CHUNK_BYTES + 1);
        await write(plain.slice(from, to), Math.max(start, index * MEDIA_PLAINTEXT_CHUNK_BYTES) - start);
        check(options, engine);
        options.onProgress?.(Math.min(end - start + 1, index * MEDIA_PLAINTEXT_CHUNK_BYTES + to - start), end - start + 1);
      }
      return { size: session.size, start, end };
    } };
  } catch (error) {
    await close();
    throw error;
  }
}

// ../../packages/agent-net/src/socketEvents.ts
var SocketEvents = class {
  constructor() {
    __publicField(this, "listeners", /* @__PURE__ */ new Map());
  }
  on(event, listener) {
    let set = this.listeners.get(event);
    if (!set) this.listeners.set(event, set = /* @__PURE__ */ new Set());
    set.add(listener);
    return this;
  }
  once(event, listener) {
    const wrapped = (...args) => {
      this.off(event, wrapped);
      listener(...args);
    };
    return this.on(event, wrapped);
  }
  off(event, listener) {
    this.listeners.get(event)?.delete(listener);
    return this;
  }
  removeListener(event, listener) {
    return this.off(event, listener);
  }
  removeAllListeners(event) {
    if (event === void 0) this.listeners.clear();
    else this.listeners.delete(event);
    return this;
  }
  emit(event, ...args) {
    const set = this.listeners.get(event);
    for (const listener of [...set ?? []]) listener(...args);
    return !!set?.size;
  }
};

// ../../packages/agent-net/src/scopedRoutes.ts
function delegatedPeerKey(d, remote, deviceId) {
  try {
    if (remote === "host") return d.kind === "shared-task" ? sharedTaskHostPeer(d.resourceId, deviceId) : providerShareHostPeer(d.resourceId, deviceId);
    if (!d.scope) return null;
    return d.kind === "shared-task" ? sharedTaskGuestPeer(d.resourceId, d.scope.memberId, d.guestDeviceId) : providerShareGuestPeer(d.resourceId, d.scope.memberId, d.guestDeviceId);
  } catch {
    return null;
  }
}
function delegatedPeerTarget(d, peer, localRole) {
  const p = d.kind === "shared-task" ? parseSharedTaskPeer(peer) : parseProviderSharePeer(peer);
  const resourceId = p && ("sharedTaskId" in p ? p.sharedTaskId : p.shareId);
  if (!p || !d.scope || resourceId !== d.resourceId || p.role === localRole) return null;
  if (localRole === "guest") {
    const endpoint3 = delegationEndpointCertificate(d, p.deviceId);
    return endpoint3 ? { relayId: p.deviceId, transportKey: endpoint3.transportKey, delegation: d } : null;
  }
  return p.role === "guest" && p.memberId === d.scope.memberId && p.deviceId === d.guestDeviceId ? { relayId: "guest:" + d.id, transportKey: d.guestTransportKey, delegation: d } : null;
}
var guestKinds = /* @__PURE__ */ new Set(["link-open", "link-close", "invoke", "push"]);
var hostKinds = /* @__PURE__ */ new Set(["link-accept", "link-close", "invoke-result", "push"]);
function guestAck(value) {
  const frame = value;
  if (!frame || typeof frame !== "object" || Array.isArray(frame) || "__cindyDeviceLinkTransport" in frame || frame.channel !== "__cindy/device-link/transport-ack") return false;
  const ack = frame.payload;
  return !!ack && typeof ack === "object" && !Array.isArray(ack) && typeof ack.streamId === "string" && Number.isSafeInteger(ack.ackSeq) && Number(ack.ackSeq) >= 0 && (ack.linkRequestId === void 0 || typeof ack.linkRequestId === "string" && ack.linkRequestId.length >= 1 && ack.linkRequestId.length <= 256);
}
function scopedFrame(delegation, frame, sender, endpoint3 = delegation.hostDeviceId) {
  const member = delegation.scope;
  if (!member || !delegationEndpointCertificate(delegation, endpoint3) || !(sender === "guest" ? guestKinds : hostKinds).has(frame.kind)) return null;
  const provider = delegation.kind === "provider-share";
  if (provider ? frame.sharedTask !== void 0 : frame.providerShare !== void 0) return null;
  const scope = provider ? parseProviderShareScope(frame.providerShare) : parseSharedTaskScope(frame.sharedTask);
  if (!scope || (provider ? scope.shareId : scope.sharedTaskId) !== delegation.resourceId) return null;
  const toGuest = sender === "host";
  if (scope.target.role !== (toGuest ? "guest" : "host") || scope.target.role === "guest" && scope.target.memberId !== member.memberId || frame.dst !== (toGuest ? delegation.guestDeviceId : endpoint3) || sender === "guest" && frame.kind === "push" && !guestAck(frame.payload)) return null;
  const guest = { role: "guest", memberId: member.memberId }, host = { role: "host" };
  const roles = { source: toGuest ? host : guest, target: toGuest ? guest : host };
  return {
    ...frame,
    src: toGuest ? endpoint3 : delegation.guestDeviceId,
    ...provider ? { providerShare: { shareId: delegation.resourceId, ...roles } } : { sharedTask: { sharedTaskId: delegation.resourceId, ...roles } }
  };
}
function frameMatchesDelegation(delegation, frame) {
  const scope = delegation.kind === "provider-share" ? parseProviderShareScope(frame.providerShare) : parseSharedTaskScope(frame.sharedTask);
  return !!delegation.scope && !!scope && (delegation.kind === "provider-share" ? scope.shareId : scope.sharedTaskId) === delegation.resourceId && scope.target.role === "guest" && scope.target.memberId === delegation.scope.memberId && frame.dst === delegation.guestDeviceId;
}

// ../../packages/agent-net/src/types.ts
var MAX_CHANNEL_PENDING_BYTES = 8 * 1024 * 1024;
var AGENT_NET_SESSION_V1 = "agent-net-session-v1";
var SESSION_LANE_KINDS = { control: 48, normal: 49, background: 50 };
var SESSION_LANE_PRIORITY = { control: "interactive", normal: "normal", background: "background" };
var MAX_EARLY_SESSION_BYTES = 16 * 1024 * 1024;
var DRAIN_LOW_WATER_BYTES = 128 * 1024;
var ChannelEvents = class {
  constructor() {
    __publicField(this, "dataHandler", null);
    __publicField(this, "closeHandler", null);
    __publicField(this, "early", []);
    __publicField(this, "closedEarly", false);
    __publicField(this, "closed", false);
  }
  onData(handler) {
    this.dataHandler = handler;
    for (const bytes of this.early.splice(0)) handler(bytes);
  }
  onClose(handler) {
    this.closeHandler = handler;
    if (this.closedEarly) handler();
  }
  data(bytes) {
    if (this.dataHandler) this.dataHandler(bytes);
    else this.early.push(bytes);
  }
  close() {
    if (this.closed) return;
    this.closed = true;
    if (this.closeHandler) this.closeHandler();
    else this.closedEarly = true;
  }
};

// ../../packages/agent-net/src/session/lanes.ts
var SESSION_LANES = ["control", "normal", "background"];
var MAX_SESSION_MESSAGE_BYTES = 16 * 1024 * 1024;
var BULK_REQUEST_BYTES = 256 * 1024;
var MAX_SESSION_HELD_BYTES = 64 * 1024 * 1024;
var LANE_INDEX = { control: 0, normal: 1, background: 2 };
var encoder = new TextEncoder();
var decoder = new TextDecoder();
function isCount(value) {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}
function isFrame(value, lane) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const { c, p, r, b, o } = value;
  return (c === "control" || c === "request" || c === "result" || c === "push") && (p === void 0 || Array.isArray(p) && p.length === SESSION_LANES.length && p.every(isCount)) && (r === void 0 || isCount(r)) && (b === void 0 || isCount(b)) && (o === void 0 || o === 1 && c === "request" && lane === "background");
}
var SessionLanes = class {
  constructor(options) {
    __publicField(this, "options", options);
    __publicField(this, "sentPushes", [0, 0, 0]);
    __publicField(this, "sentNormalRequests", 0);
    __publicField(this, "deliveredPushes", [0, 0, 0]);
    __publicField(this, "deliveredNormalRequests", 0);
    __publicField(this, "sentMovedRequests", 0);
    __publicField(this, "deliveredMovedRequests", 0);
    __publicField(this, "inbound", SESSION_LANES.map(() => ({ chunks: [], length: 0, queue: [], busy: false })));
    __publicField(this, "heldBytes", 0);
    __publicField(this, "closed", false);
    __publicField(this, "pumping", false);
    __publicField(this, "pumpAgain", false);
  }
  /** Writes one message; returns the lane it actually went on (a bulk request moves to background, see BULK_REQUEST_BYTES). */
  send(lane, kind, message, options = {}) {
    if (this.closed) throw new Error("AGENT_NET_SESSION_CLOSED");
    const frame = { m: message, c: kind };
    if (kind === "result" || options.afterEarlier) frame.p = [...this.sentPushes];
    if (kind === "request" && lane === "control" || options.afterEarlier) frame.r = this.sentNormalRequests;
    const ordered = kind === "request" && lane !== "background" && !options.unordered || options.afterEarlier;
    if (ordered && this.sentMovedRequests > 0) frame.b = this.sentMovedRequests;
    let body = encoder.encode(JSON.stringify(frame));
    let moved = false;
    if (kind === "request" && lane !== "background" && body.length > BULK_REQUEST_BYTES) {
      lane = "background";
      moved = true;
      frame.r = this.sentNormalRequests;
      delete frame.b;
      if (!options.unordered) frame.o = 1;
      body = encoder.encode(JSON.stringify(frame));
    }
    const index = LANE_INDEX[lane];
    if (body.length > MAX_SESSION_MESSAGE_BYTES) throw new Error("PAYLOAD_TOO_LARGE");
    const bytes = new Uint8Array(4 + body.length);
    new DataView(bytes.buffer).setUint32(0, body.length, false);
    bytes.set(body, 4);
    this.options.write(lane, bytes);
    if (kind === "push") this.sentPushes[index]++;
    if (kind === "request" && lane === "normal") this.sentNormalRequests++;
    if (moved && !options.unordered) this.sentMovedRequests++;
    return lane;
  }
  /**
   * Feed bytes read from the lane's core stream (any chunking). The lane keeps `bytes` until its frame is complete, so
   * the caller must not reuse the array. Chunks are joined once per frame: a 512 KiB result arrives in hundreds of
   * packet-sized chunks, and copying the partial frame on every chunk was a fifth of a CPU-bound transfer.
   */
  receive(lane, bytes) {
    if (this.closed) return;
    const state = this.inbound[LANE_INDEX[lane]];
    if (bytes.length) {
      state.chunks.push(bytes);
      state.length += bytes.length;
    }
    while (state.length >= 4) {
      const head = peek(state, 4);
      const length = new DataView(head.buffer, head.byteOffset, 4).getUint32(0, false);
      if (length > MAX_SESSION_MESSAGE_BYTES) {
        this.fail(new Error("AGENT_NET_SESSION_FRAME_TOO_LARGE"));
        return;
      }
      if (state.length < 4 + length) break;
      const body = take(state, 4 + length).subarray(4);
      let frame;
      try {
        frame = JSON.parse(decoder.decode(body));
      } catch {
        this.fail(new Error("AGENT_NET_SESSION_FRAME_INVALID"));
        return;
      }
      if (!isFrame(frame, lane)) {
        this.fail(new Error("AGENT_NET_SESSION_FRAME_INVALID"));
        return;
      }
      state.queue.push({ frame, bytes: length });
      this.heldBytes += length;
    }
    if (this.heldBytes + state.length > MAX_SESSION_HELD_BYTES) {
      this.fail(new Error("AGENT_NET_SESSION_BACKLOG"));
      return;
    }
    this.pump();
  }
  close() {
    this.closed = true;
    for (const state of this.inbound) {
      state.queue.length = 0;
      state.chunks = [];
      state.length = 0;
    }
    this.heldBytes = 0;
  }
  ready(lane, frame) {
    if (frame.p && frame.p.some((count, index) => index !== lane && this.deliveredPushes[index] < count)) return false;
    if (frame.r !== void 0 && this.deliveredNormalRequests < frame.r) return false;
    if (frame.b !== void 0 && this.deliveredMovedRequests < frame.b) return false;
    return true;
  }
  /** Hands over every ready lane head. Iterative, so a long run of synchronous handlers does not grow the stack. */
  pump() {
    if (this.pumping) {
      this.pumpAgain = true;
      return;
    }
    this.pumping = true;
    try {
      do {
        this.pumpAgain = false;
        for (let lane = 0; lane < this.inbound.length && !this.closed; lane++) {
          const state = this.inbound[lane];
          while (!state.busy && !this.closed) {
            const head = state.queue[0];
            if (!head || !this.ready(lane, head.frame)) break;
            state.queue.shift();
            this.heldBytes -= head.bytes;
            state.busy = true;
            let result = void 0;
            try {
              result = this.options.deliver(head.frame.m, SESSION_LANES[lane]);
            } catch {
              result = void 0;
            }
            if (result && typeof result.then === "function") {
              const settle = () => {
                this.delivered(lane, head.frame);
                this.pump();
              };
              result.then(settle, settle);
            } else {
              this.delivered(lane, head.frame);
              this.pumpAgain = true;
            }
          }
        }
      } while (this.pumpAgain && !this.closed);
    } finally {
      this.pumping = false;
    }
  }
  delivered(lane, frame) {
    this.inbound[lane].busy = false;
    if (frame.c === "push") this.deliveredPushes[lane]++;
    if (frame.c === "request" && lane === LANE_INDEX.normal) this.deliveredNormalRequests++;
    if (frame.c === "request" && frame.o === 1) this.deliveredMovedRequests++;
  }
  fail(error) {
    if (this.closed) return;
    this.close();
    this.options.onError(error);
  }
};
function peek(state, count) {
  const first = state.chunks[0];
  if (first.length >= count) return first.subarray(0, count);
  const out = new Uint8Array(count);
  let filled = 0;
  for (const chunk of state.chunks) {
    const part = chunk.subarray(0, count - filled);
    out.set(part, filled);
    filled += part.length;
    if (filled === count) break;
  }
  return out;
}
function take(state, count) {
  state.length -= count;
  const first = state.chunks[0];
  if (first.length >= count) {
    if (first.length === count) state.chunks.shift();
    else state.chunks[0] = first.subarray(count);
    return first.subarray(0, count);
  }
  const out = new Uint8Array(count);
  let filled = 0, used = 0;
  while (filled < count) {
    const chunk = state.chunks[used];
    const part = chunk.subarray(0, count - filled);
    out.set(part, filled);
    filled += part.length;
    if (part.length === chunk.length) used++;
    else state.chunks[used] = chunk.subarray(part.length);
  }
  state.chunks.splice(0, used);
  return out;
}

// ../../packages/agent-net/src/session/peer.ts
var SENDS = {
  call: /* @__PURE__ */ new Set(["open", "invoke", "cancel", "close"]),
  serve: /* @__PURE__ */ new Set(["accept", "reject", "result", "push", "close"])
};
var RECEIVES = { call: SENDS.serve, serve: SENDS.call };
var MAX_CANCELLED_REQUESTS = 1024;
var nextId = 0;
var newId = () => `s${Date.now().toString(36)}-${(++nextId).toString(36)}`;
var SessionPeer = class {
  constructor(options) {
    __publicField(this, "options", options);
    __publicField(this, "lanes");
    __publicField(this, "pending", /* @__PURE__ */ new Map());
    __publicField(this, "opening", /* @__PURE__ */ new Map());
    /** Lane each inbound request arrived on, so its result goes back on the same lane. */
    __publicField(this, "inboundLane", /* @__PURE__ */ new Map());
    __publicField(this, "broken", null);
    __publicField(this, "cancelled", /* @__PURE__ */ new Set());
    /**
     * Smallest (this side's clock when a request arrived − the sender's clock when it wrote it) on this session: the offset
     * between the two clocks plus the fastest trip. How much later than that a request arrives is how long it was held up
     * (a stalled path, a retransmission, a wait in this side's lane queue); neither clock has to agree with the other.
     */
    __publicField(this, "lagFloor", null);
    /** Receiver clock minus sender clock, measured from an authenticated link acceptance. Travel time makes this a lower bound. */
    __publicField(this, "peerClockLowerBound");
    this.lanes = new SessionLanes({
      write: (lane, bytes) => options.wire.write(lane, bytes),
      deliver: (message, lane) => this.deliver(message, lane),
      onError: (error) => this.dispose(error.message)
    });
    options.wire.onData((lane, bytes) => this.lanes.receive(lane, bytes));
  }
  get bufferedAmount() {
    return this.options.wire.bufferedAmount;
  }
  get closedReason() {
    return this.broken;
  }
  /** Ask the peer for its control link; resolves with its accept payload. */
  open(payload, timeoutMs, onSettled) {
    const fail = (error) => {
      onSettled?.({ error });
      return Promise.reject(error);
    };
    if (this.broken) return fail(new SessionError(this.broken, "session closed"));
    if (!this.maySend("open")) return fail(forbidden("open"));
    const id = newId();
    return new Promise((resolve, reject) => {
      const accepted = (opened) => {
        onSettled?.({ opened });
        resolve(opened);
      };
      const refused = (error) => {
        onSettled?.({ error });
        reject(error);
      };
      const timer = setTimeout(() => {
        this.opening.delete(id);
        refused(new SessionError("LINK_TIMEOUT", "no answer to session open"));
      }, timeoutMs);
      this.opening.set(id, { resolve: accepted, reject: refused, timer });
      this.send("control", "control", { t: "open", id, payload });
    });
  }
  accept(id, payload) {
    this.send("control", "control", { t: "accept", id, payload, at: performance.now() });
  }
  reject(id, code, message) {
    this.send("control", "control", { t: "reject", id, code, message });
  }
  close(reason) {
    if (!this.broken) this.send("control", "control", { t: "close", reason }, { afterEarlier: true });
  }
  presence(payload) {
    if (!this.broken) this.send("control", "control", { t: "presence", payload });
  }
  /**
   * Calls a channel on the peer. A request that was never written fails with `NOT_SENT` and is safe to retry; one that was
   * written and then lost to a timeout or a dropped connection may have run (`INVOKE_TIMEOUT` / `DEVICE_OFFLINE`).
   * After a timeout the peer does not start it any more (docs/agent-net-session-plan.md §5.4): a cancel goes out on the
   * control lane, and a request that reaches the peer later than its time limit is dropped there, which also covers a
   * cancel overtaken by the request's own retransmission after a stall.
   */
  request(channel, args, options = {}) {
    const settled = (result) => {
      options.onSettled?.(result);
      return Promise.resolve(result);
    };
    if (this.broken) return settled(failure(this.broken, "session closed"));
    if (!this.maySend("invoke")) return settled(failure("FORBIDDEN", forbidden("invoke").message));
    const id = options.id ?? newId();
    if (this.pending.has(id)) return settled(failure("NOT_SENT", "request id already in flight on this session"));
    const lane = options.lane ?? this.options.laneFor(channel, options.background);
    return new Promise((done) => {
      const resolve = (result) => {
        options.onSettled?.(result);
        done(result);
      };
      const entry = { resolve, timer: null, written: false };
      const timeoutMs = options.timeoutMs;
      if (timeoutMs !== void 0) {
        entry.timer = setTimeout(() => {
          if (!this.pending.delete(id)) return;
          if (entry.written && !this.broken) {
            try {
              this.send("control", "control", { t: "cancel", id });
            } catch {
            }
          }
          resolve(failure("INVOKE_TIMEOUT", `no result within ${timeoutMs}ms`));
        }, timeoutMs);
      }
      this.pending.set(id, entry);
      try {
        const now2 = performance.now();
        const deadline = timeoutMs !== void 0 && this.peerClockLowerBound !== void 0 ? now2 + timeoutMs + this.peerClockLowerBound : void 0;
        this.send(
          lane,
          "request",
          {
            t: "invoke",
            id,
            channel,
            args,
            ...options.extra ? { x: options.extra } : {},
            at: Math.round(now2),
            ...timeoutMs !== void 0 ? { ms: timeoutMs } : {},
            ...deadline !== void 0 ? { deadline } : {}
          },
          { unordered: options.unordered }
        );
        entry.written = true;
      } catch (error) {
        this.settle(id, failure(error instanceof Error && error.message === "PAYLOAD_TOO_LARGE" ? "PAYLOAD_TOO_LARGE" : "NOT_SENT", String(error)));
      }
    });
  }
  respond(id, result) {
    const lane = this.inboundLane.get(id) ?? "normal";
    this.send(lane, "result", { t: "result", id, result });
    this.inboundLane.delete(id);
  }
  push(channel, payload) {
    this.send("normal", "push", { t: "push", channel, payload });
  }
  /** The connection is gone or unusable: fail everything still waiting. Idempotent. */
  dispose(code) {
    if (this.broken) return;
    this.broken = code;
    this.lanes.close();
    for (const [id, entry] of this.pending) {
      if (entry.timer) clearTimeout(entry.timer);
      this.pending.delete(id);
      entry.resolve(failure(entry.written ? "DEVICE_OFFLINE" : "NOT_SENT", `session ${code}`));
    }
    for (const [id, open] of this.opening) {
      clearTimeout(open.timer);
      this.opening.delete(id);
      open.reject(new SessionError("DEVICE_OFFLINE", `session ${code}`));
    }
    this.inboundLane.clear();
    this.options.onBroken?.(code);
  }
  send(lane, kind, message, options) {
    if (this.broken) throw new SessionError(this.broken, "session closed");
    if (!this.maySend(message.t)) throw forbidden(message.t);
    return this.lanes.send(lane, kind, message, options);
  }
  maySend(type) {
    const role = this.options.role ?? "both";
    return role === "both" || SENDS[role].has(type);
  }
  /** The caller cancelled this request, or its time limit passed before it got here (see `lagFloor`). */
  lateOrCancelled(message) {
    if (this.cancelled.delete(message.id)) return true;
    if (typeof message.deadline === "number" && Number.isFinite(message.deadline)) {
      return performance.now() >= message.deadline;
    }
    const arrivedLag = lag(message);
    if (arrivedLag === null) return false;
    this.lagFloor = this.lagFloor === null ? arrivedLag : Math.min(this.lagFloor, arrivedLag);
    return typeof message.ms === "number" && arrivedLag - this.lagFloor >= message.ms;
  }
  settle(id, result) {
    const entry = this.pending.get(id);
    if (!entry) return;
    this.pending.delete(id);
    if (entry.timer) clearTimeout(entry.timer);
    entry.resolve(result);
  }
  deliver(message, arrivedOn) {
    const role = this.options.role ?? "both";
    if (role !== "both" && !RECEIVES[role].has(message?.t)) return;
    switch (message?.t) {
      case "invoke": {
        if (typeof message.id !== "string" || typeof message.channel !== "string" || !Array.isArray(message.args)) return;
        if (this.lateOrCancelled(message)) return;
        this.inboundLane.set(message.id, arrivedOn);
        const extra = message.x && typeof message.x === "object" && !Array.isArray(message.x) ? message.x : void 0;
        return this.options.onRequest?.({ id: message.id, channel: message.channel, args: message.args, lane: arrivedOn, ...extra ? { extra } : {} });
      }
      case "result":
        this.settle(message.id, message.result);
        return;
      case "push":
        return this.options.onPush?.(message.channel, message.payload);
      case "open":
        return this.options.onOpen?.(message.id, message.payload);
      case "accept":
      case "reject": {
        const open = this.opening.get(message.id);
        if (!open) return;
        this.opening.delete(message.id);
        clearTimeout(open.timer);
        if (message.t === "accept") {
          this.peerClockLowerBound = typeof message.at === "number" && Number.isFinite(message.at) ? message.at - performance.now() : void 0;
          open.resolve(message.payload);
        } else open.reject(new SessionError(message.code, message.message));
        return;
      }
      case "cancel": {
        if (typeof message.id !== "string" || this.inboundLane.has(message.id)) return;
        if (this.cancelled.size >= MAX_CANCELLED_REQUESTS) this.cancelled.delete(this.cancelled.values().next().value);
        this.cancelled.add(message.id);
        return;
      }
      case "close":
        return this.options.onClose?.(message.reason);
      case "presence":
        return this.options.onPresence?.(message.payload);
    }
  }
};
function lag(message) {
  return typeof message.at === "number" && Number.isFinite(message.at) ? performance.now() - message.at : null;
}
var SessionError = class extends Error {
  constructor(code, message) {
    super(message);
    __publicField(this, "code", code);
  }
};
var failure = (code, message) => ({ ok: false, error: { code, message } });
var forbidden = (type) => new SessionError("FORBIDDEN", `this side of a one-way session does not send ${type}`);

// ../../packages/agent-net/src/portableSocket.ts
var REDIAL_TAKEOVER_MS = 1e4;
var REDIAL_FIRST_MS = 1e3;
var REDIAL_MAX_MS = 3e4;
var SESSION_PRESENCE_FEATURE = "presence-v1";
var PRESENCE_DECLARATION_WAIT_MS = 1500;
var NOTIFY_QUEUE_LIMIT = 32;
function peerRuleOf(rule) {
  const ids = (list) => new Set(list.filter((id) => typeof id === "string"));
  return { allowed: Array.isArray(rule.allowed) ? ids(rule.allowed) : null, refused: Array.isArray(rule.refused) ? ids(rule.refused) : /* @__PURE__ */ new Set() };
}
function unrefTimer(timer) {
  if (typeof timer !== "number") timer.unref?.();
}
var Frames = class {
  constructor() {
    __publicField(this, "chunks", []);
    __publicField(this, "bytes", 0);
    __publicField(this, "expected", null);
  }
  push(input, consume) {
    this.chunks.push(input.slice());
    this.bytes += input.length;
    for (; ; ) {
      if (this.expected === null) {
        if (this.bytes < 4) return;
        const header = this.take(4);
        this.expected = new DataView(header.buffer, header.byteOffset, 4).getUint32(0, false);
        if (this.expected < 1 || this.expected > MAX_FRAME_BYTES2) throw new Error("INVALID_FRAME_LENGTH");
      }
      if (this.bytes < this.expected) return;
      const value = JSON.parse(decodeUtf8(this.take(this.expected)));
      this.expected = null;
      if (!value || typeof value !== "object" || value.v !== PROTOCOL_VERSION || typeof value.kind !== "string") throw new Error("INVALID_FRAME");
      consume(value);
    }
  }
  take(size) {
    this.bytes -= size;
    const first = this.chunks[0];
    if (first.length >= size) {
      if (first.length === size) this.chunks.shift();
      else this.chunks[0] = first.subarray(size);
      return first.subarray(0, size);
    }
    const merged = concatBytes(this.chunks);
    this.chunks = merged.length === size ? [] : [merged.subarray(size)];
    return merged.subarray(0, size);
  }
};
var AgentNetSocket = class extends SocketEvents {
  constructor(options) {
    super();
    __publicField(this, "options", options);
    __publicField(this, "transport");
    __publicField(this, "uplink", null);
    __publicField(this, "receiveDatagram", null);
    __publicField(this, "roster", /* @__PURE__ */ new Map());
    /** Which members of this account's directory this node accepts (restrictPeers); null: all of them. */
    __publicField(this, "peerRule", { allowed: null, refused: /* @__PURE__ */ new Set() });
    __publicField(this, "delegations", /* @__PURE__ */ new Map());
    __publicField(this, "ownDelegation", null);
    __publicField(this, "knownV2", /* @__PURE__ */ new Set());
    __publicField(this, "peers", /* @__PURE__ */ new Map());
    __publicField(this, "dialing", /* @__PURE__ */ new Map());
    __publicField(this, "redials", /* @__PURE__ */ new Map());
    __publicField(this, "redialSteps", /* @__PURE__ */ new Map());
    __publicField(this, "pending", /* @__PURE__ */ new Map());
    __publicField(this, "pendingBytes", 0);
    __publicField(this, "sentRequests", /* @__PURE__ */ new Map());
    __publicField(this, "closed", false);
    __publicField(this, "ready", false);
    __publicField(this, "localHello", null);
    __publicField(this, "reconnect", null);
    __publicField(this, "generation", 0);
    __publicField(this, "retryMs", 500);
    __publicField(this, "rosterValidUntil", 0);
    __publicField(this, "lan", null);
    __publicField(this, "lanCandidates", /* @__PURE__ */ new Map());
    __publicField(this, "directoryRevision", 0);
    __publicField(this, "directoryRefresh");
    __publicField(this, "refreshingDirectory", false);
    __publicField(this, "notificationAbort", new AbortController());
    __publicField(this, "notifying", false);
    __publicField(this, "notifyQueue", []);
    __publicField(this, "drainArmed", false);
    /**
     * Agent-Net sessions (docs/agent-net-session-plan.md §10.1), the independent upper layer that replaces Device Link
     * frames between two new nodes. Off until `useSessions` is called. A session exists while the peer's encrypted
     * connection does and the peer declared support. Between devices of one account it is keyed by the device; inside a
     * delegation (a guest admitted to a shared task or provider share) by the scoped peer the delegation names, and one-way
     * (`sessionScope`). Every message in either direction re-checks that the peer is still authorized for that same scope.
     * Device Link frames on this socket are unaffected either way.
     */
    __publicField(this, "sessionConfig", null);
    /** By session key (see `SessionConfig.handlers`); `deviceId` is the connection it runs on. */
    __publicField(this, "sessions", /* @__PURE__ */ new Map());
    /** Connection (directory or delegation id) → the key of the session on it. */
    __publicField(this, "sessionKeys", /* @__PURE__ */ new Map());
    /**
     * Signature checks are cached per certificate / delegation object. `authorized` runs for every datagram and every chunk
     * read (one Ed25519 verify is ~50–100 µs, which capped loopback throughput); roster and grant objects are only replaced
     * on directory updates, and a verified object stays valid until its own expiry, after which it is checked again.
     * Only successes are cached, so a not-yet-valid certificate is re-checked.
     */
    __publicField(this, "verified", /* @__PURE__ */ new WeakMap());
    /**
     * Transport key (hex) → the ids carrying it, in `peerIds` order, and each id's key. The phone's engine asks for every
     * connection on every poll and once per admitted peer: going through the directory and converting every key each time
     * was O(N²) per poll, most of a poll's cost with a few dozen devices (2026-11-20 on a phone, polls every 8 ms took
     * 55–60% of the JS thread before, 22–33% after). Rebuilt whenever the directory changes; who is authorized is still
     * checked on every lookup.
     */
    __publicField(this, "keyIndex", null);
    __publicField(this, "resendWhenRelayBack", false);
  }
  static async openWithBindings(options) {
    const socket = new this(options);
    socket.rosterValidUntil = options.directoryExpiresAt ?? 0;
    if (options.peerRule) socket.peerRule = peerRuleOf(options.peerRule);
    socket.updateDirectory((options.cachedDirectory ?? []).map((view) => ({ ...view, online: false })), false);
    try {
      await socket.connectRelay();
    } catch (error) {
      if (socket.closed || socket.roster.size === 0) {
        socket.close();
        throw error;
      }
      socket.scheduleReconnect();
    }
    try {
      socket.transport = await options.bindings.createTransport({
        relay: { deviceId: options.client.identity.deviceId, uplink: {
          kind: "agent-net",
          send: (id, data) => {
            if (socket.authorized(id)) socket.uplink?.send(id, data);
          },
          onDatagram: (receive) => {
            socket.receiveDatagram = receive;
          },
          close: () => void 0
        }, udpCredentials: () => socket.uplink?.udp ?? null },
        admit: (key3) => socket.deviceForKey(key3) !== void 0,
        admissionVersion: () => socket.directoryRevision,
        relayIdOf: (key3) => socket.deviceForKey(key3),
        admittedPeers: () => socket.peerIds().filter((id) => socket.authorized(id)).map((id) => ({ id: socket.transportKeyHex(id), relayId: id })),
        onIncoming: (channel) => socket.adopt(channel, false)
      });
      socket.uplink?.onDatagram((id, data) => socket.receiveDatagram?.(id, data));
      const dial = socket.transport.dial;
      if (options.bindings.createDiscovery && options.lanDiscovery !== false && dial.udp && !options.client.delegation) {
        socket.lan = options.bindings.createDiscovery({
          networkId: options.client.certificate.networkId,
          port: dial.udp.port,
          certificateFor: (id) => socket.authorized(id) ? socket.roster.get(id)?.certificate : void 0,
          onCandidate(id, address) {
            if (!socket.authorized(id)) return;
            socket.lanCandidates.set(id, address);
            if (socket.ready && !socket.peers.has(id)) void socket.dial(id).catch(() => void 0);
          }
        });
        socket.lan.start();
      }
      socket.directoryRefresh = setInterval(() => {
        void socket.refreshDirectory().catch(() => void 0);
      }, 6 * 60 * 6e4);
      unrefTimer(socket.directoryRefresh);
      setTimeout(() => {
        if (!socket.closed) socket.emit("open");
      }, 0);
      return socket;
    } catch (error) {
      socket.close();
      throw error;
    }
  }
  get bufferedAmount() {
    let bytes = this.pendingBytes;
    for (const peer of this.peers.values()) bytes += peer.channel.bufferedAmount ?? 0;
    return bytes;
  }
  /**
   * `bufferedAmount` fell back to {@link DRAIN_LOW_WATER_BYTES} or below after having been above it: an upper layer that
   * stops writing above a watermark can resume right away instead of polling. Once per crossing, not per core write:
   * per-write events cost the shared Main thread more than they saved (2026-11-14 bench, downloads 2.6x slower).
   */
  onDrain(listener) {
    this.on("drain", listener);
  }
  useSessions(config) {
    this.sessionConfig = config;
    for (const [deviceId, peer] of this.peers) this.attachSession(deviceId, peer);
  }
  /** The live session for this key, if both sides support sessions and the connection is up. */
  session(key3) {
    return this.sessions.get(key3)?.session ?? null;
  }
  /** The connection a session key's live session runs on. */
  sessionDevice(key3) {
    return this.sessions.get(key3)?.deviceId ?? null;
  }
  onSession(listener) {
    this.on("session", listener);
  }
  /**
   * Connects to the peer a session key names, for a caller that wants its session before the first message: a guest dials
   * the resource's computer on demand; a device of this account is dialed when the directory says it is online now (only
   * one side of a pair dials from the directory by itself, and a message to an unconnected peer would otherwise go out as a
   * Device Link frame before the session exists). Resolves true once the connection is up (its session follows if the peer
   * supports sessions), false if there is no such peer to dial from here, it is not online, or the dial failed. The
   * resource's side never dials a guest.
   */
  async connectSession(key3) {
    if (this.closed || !this.sessionConfig) return false;
    const deviceId = this.sessions.get(key3)?.deviceId ?? (this.options.client.delegation ? this.scopedPeerTarget(key3)?.relayId : this.roster.has(key3) && this.sessionScope(key3) && (this.peers.has(key3) || this.roster.get(key3).online === true) ? key3 : void 0);
    if (!deviceId) return false;
    if (!this.peers.has(deviceId)) {
      try {
        await this.dial(deviceId);
      } catch {
        return false;
      }
    }
    return this.peers.has(deviceId);
  }
  /**
   * Whom a session on this connection is for, and which end of the control link this side may be. Between devices of one
   * account: the device, both ends. Inside a delegation: the scoped peer it names (`delegatedPeerKey`); the guest only
   * calls, the resource's computers only serve, as with scoped Device Link frames. Null: no session here (a delegation
   * without a member scope, or `delegatedOnly` and not a delegation).
   */
  sessionScope(deviceId) {
    if (this.options.client.delegation) {
      const own = this.ownDelegation;
      const key3 = own?.scope && delegationEndpointCertificate(own, deviceId) ? delegatedPeerKey(own, "host", deviceId) : null;
      return key3 ? { key: key3, role: "call" } : null;
    }
    const delegation = this.delegations.get(deviceId);
    if (delegation) {
      const key3 = delegatedPeerKey(delegation, "guest", delegation.guestDeviceId);
      return key3 ? { key: key3, role: "serve" } : null;
    }
    if (deviceId.startsWith("guest:") || this.sessionConfig?.delegatedOnly) return null;
    return { key: deviceId, role: "both" };
  }
  attachSession(deviceId, peer) {
    const scope = this.sessionConfig ? this.sessionScope(deviceId) : null;
    if (!scope) return;
    peer.channel.declareSessions?.(scope.role === "both" ? [SESSION_PRESENCE_FEATURE] : []);
    peer.channel.onSessionCapable?.(() => {
      const config = this.sessionConfig, wire = peer.channel.sessionWire?.();
      if (!config || !wire || this.closed || this.peers.get(deviceId) !== peer || this.sessions.has(scope.key) || this.sessionScope(deviceId)?.key !== scope.key) return;
      const handlers = config.handlers(scope.key);
      let session;
      const current = () => this.authorized(deviceId) && this.peers.get(deviceId) === peer && this.sessionScope(deviceId)?.key === scope.key;
      const guard = (handler) => handler && ((...args) => {
        if (!current()) {
          session.dispose("UNAUTHORIZED");
          return;
        }
        return handler(...args);
      });
      const checked = {
        write: (lane, bytes) => {
          if (!current()) {
            queueMicrotask(() => session.dispose("UNAUTHORIZED"));
            throw new Error("UNAUTHORIZED");
          }
          wire.write(lane, bytes);
        },
        get bufferedAmount() {
          return wire.bufferedAmount;
        },
        onData: (handler) => wire.onData(handler)
      };
      session = new SessionPeer({
        wire: checked,
        role: scope.role,
        laneFor: config.laneFor,
        onOpen: guard(handlers.onOpen),
        onClose: guard(handlers.onClose),
        onRequest: guard(handlers.onRequest),
        onPush: guard(handlers.onPush),
        // This socket keeps presence for its Device Link client: a peer's session presence becomes the same local event as its frame.
        onPresence: scope.role === "both" ? guard((payload) => this.peerPresence(peer, payload)) : guard(handlers.onPresence),
        onBroken: (code) => {
          if (this.sessions.get(scope.key)?.session === session) this.sessions.delete(scope.key);
          if (this.sessionKeys.get(deviceId) === scope.key) this.sessionKeys.delete(deviceId);
          handlers.onBroken?.(code);
          if (code === "UNAUTHORIZED" || code.startsWith("AGENT_NET_SESSION_")) peer.channel.close();
        }
      });
      this.sessions.set(scope.key, { peer, session, deviceId });
      this.sessionKeys.set(deviceId, scope.key);
      this.emit("session", scope.key, session, deviceId);
      if (scope.role === "both" && peer.presenceWait) {
        clearTimeout(peer.presenceWait);
        peer.presenceWait = void 0;
        this.sendPresence(peer);
      }
    });
  }
  get deviceId() {
    return this.options.client.identity.deviceId;
  }
  /** A REST response cannot overwrite a newer WebSocket directory event. */
  async refreshDirectory() {
    const client = this.options.client, revision = this.directoryRevision, generation = this.generation;
    if (this.closed || !this.uplink || this.refreshingDirectory || !client.directory) return;
    this.refreshingDirectory = true;
    try {
      const devices = await client.directory();
      this.options.assertCurrent?.();
      if (!this.closed && this.uplink && this.options.client === client && this.generation === generation && this.directoryRevision === revision) {
        this.updateDirectory(devices);
      }
    } finally {
      this.refreshingDirectory = false;
    }
  }
  /** Renew only the relay credential; existing authenticated direct streams keep running. */
  async replaceClient(next) {
    const previous = this.options.client;
    if (this.closed || next.base !== previous.base || next.rootPublicKey !== previous.rootPublicKey || next.certificate.networkId !== previous.certificate.networkId || next.certificate.subject !== previous.certificate.subject || next.identity.deviceId !== previous.identity.deviceId || next.identity.signingKey !== previous.identity.signingKey || next.identity.transportKey !== previous.identity.transportKey) throw new Error("AGENT_NET_IDENTITY_CHANGED");
    this.options.client = next;
    const old = this.uplink;
    this.uplink = null;
    old?.close();
    if (this.ready) this.acknowledgeHello();
    if (this.reconnect) {
      clearTimeout(this.reconnect);
      this.reconnect = null;
    }
    try {
      await this.connectRelay();
    } catch (error) {
      if (!this.closed) this.scheduleReconnect();
      throw error;
    }
  }
  supports(deviceId) {
    return this.authorized(deviceId) && (this.peers.has(deviceId) || this.roster.get(deviceId)?.online === true);
  }
  /** A previously certified V2 peer must not silently downgrade when its relay session disappears. */
  knowsPeer(deviceId) {
    return this.knownV2.has(deviceId);
  }
  certificateFor(deviceId) {
    return this.roster.get(deviceId)?.certificate;
  }
  scopedPeerTarget(peer) {
    if (this.options.client.delegation) {
      const own = this.ownDelegation, target = own && delegatedPeerTarget(own, peer, "guest");
      return target && this.authorized(target.relayId) ? target : null;
    }
    for (const [id, delegation] of this.delegations) {
      const target = delegatedPeerTarget(delegation, peer, "host");
      if (target && this.authorized(id)) return target;
    }
    return null;
  }
  /** `deviceId`: a device, or a session key (its session's connection). */
  pathTo(deviceId) {
    return this.peers.get(this.sessionDevice(deviceId) ?? deviceId)?.channel.path?.() ?? null;
  }
  /** A local dial can be in progress even when the cached directory marks the peer offline. */
  isDialing(deviceId) {
    return this.dialing.has(deviceId) && this.authorized(deviceId);
  }
  peerSnapshot(deviceId) {
    const channel = this.peers.get(this.sessionDevice(deviceId) ?? deviceId)?.channel, path = channel?.path?.();
    if (!channel || !path) return null;
    const rtt = channel.stats?.()?.srttUs;
    return { path, rttMs: typeof rtt === "number" && rtt > 0 ? rtt / 1e3 : null };
  }
  async dial(deviceId) {
    if (this.closed || this.peers.has(deviceId)) return;
    const existing = this.dialing.get(deviceId);
    if (existing) return existing;
    const key3 = this.transportKey(deviceId);
    if (!key3 || !this.authorized(deviceId)) throw new Error("UNAUTHORIZED_PEER");
    const lan = this.lanCandidates.get(deviceId);
    const entry = { id: keyHex(key3), dial: { relayId: deviceId, ...lan ? { udp: lan, preferUdp: true } : {} } };
    const connect2 = async () => {
      try {
        return await this.transport.connect(entry);
      } catch (error) {
        if (!lan || !this.uplink || !this.authorized(deviceId) || keyHex(this.transportKey(deviceId)) !== entry.id) throw error;
        if (this.lanCandidates.get(deviceId) === lan) this.lanCandidates.delete(deviceId);
        return this.transport.connect({ id: entry.id, dial: { relayId: deviceId } });
      }
    };
    const dialing = connect2().then((channel) => this.adopt(channel, true));
    this.dialing.set(deviceId, dialing);
    try {
      await dialing;
    } finally {
      if (this.dialing.get(deviceId) === dialing) this.dialing.delete(deviceId);
    }
  }
  /** See REDIAL_FIRST_MS. Only devices of this account the directory has online; delegations dial on demand. */
  scheduleRedial(deviceId) {
    if (this.closed || this.redials.has(deviceId) || this.deviceId >= deviceId) return;
    if (!this.roster.get(deviceId)?.online || !this.authorized(deviceId)) return;
    const step = this.redialSteps.get(deviceId) ?? 0;
    this.redialSteps.set(deviceId, step + 1);
    const delay = Math.min(REDIAL_MAX_MS, REDIAL_FIRST_MS * 2 ** step) * (0.8 + Math.random() * 0.4);
    const timer = setTimeout(() => {
      this.redials.delete(deviceId);
      if (this.closed || this.peers.has(deviceId) || !this.roster.get(deviceId)?.online || !this.authorized(deviceId)) return;
      void this.dial(deviceId).catch(() => this.scheduleRedial(deviceId));
    }, delay);
    timer.unref?.();
    this.redials.set(deviceId, timer);
  }
  authorized(deviceId) {
    const delegate = this.delegations.get(deviceId);
    if (delegate) return !this.closed && Date.now() < this.rosterValidUntil && delegationVisibleTo(delegate, this.options.client.identity) && this.delegationValid(delegate);
    const own = this.ownDelegation, endpoint3 = own && delegationEndpointCertificate(own, deviceId);
    if (this.options.client.delegation && (!own?.scope || !endpoint3 || !this.delegationValid(own))) return false;
    const view = this.roster.get(deviceId), c = view?.certificate;
    return !this.closed && Date.now() < this.rosterValidUntil && !!c && c.deviceId !== this.deviceId && this.memberAccepted(deviceId) && this.verifiedUntil(c, () => this.options.bindings.verifyCertificate(this.options.client.rootPublicKey, c), () => c.expiresAt) && (!endpoint3 || endpoint3.signingKey === c.signingKey && endpoint3.transportKey === c.transportKey) && c.networkId === this.options.client.certificate.networkId && c.subject === this.options.client.certificate.subject;
  }
  verifiedUntil(value, check2, until) {
    const cached = this.verified.get(value);
    if (cached !== void 0 && Date.now() < cached) return true;
    if (!check2()) return false;
    this.verified.set(value, until());
    return true;
  }
  delegationValid(d) {
    return this.verifiedUntil(
      d,
      () => !!this.options.bindings.verifyDelegation?.(this.options.client.rootPublicKey, d),
      () => Math.min(d.expiresAt, d.issuerCertificate.expiresAt)
    );
  }
  keys() {
    const cached = this.keyIndex;
    if (cached && cached.roster === this.roster && cached.delegations === this.delegations.size) return cached;
    const byKey = /* @__PURE__ */ new Map(), byId = /* @__PURE__ */ new Map();
    for (const id of this.peerIds()) {
      const key3 = this.transportKey(id);
      if (!key3) continue;
      const hex = keyHex(key3);
      byId.set(id, hex);
      const ids = byKey.get(hex);
      if (ids) ids.push(id);
      else byKey.set(hex, [id]);
    }
    return this.keyIndex = { roster: this.roster, delegations: this.delegations.size, byKey, byId };
  }
  deviceForKey(hex) {
    for (const id of this.keys().byKey.get(hex) ?? []) if (this.authorized(id)) return id;
    return void 0;
  }
  /** This peer's transport key in hex (see `keys`). */
  transportKeyHex(id) {
    return this.keys().byId.get(id);
  }
  peerIds() {
    return [...this.roster.keys(), ...this.delegations.keys()];
  }
  transportKey(id) {
    return this.delegations.get(id)?.guestTransportKey ?? this.roster.get(id)?.certificate.transportKey;
  }
  updateDirectory(directory, live = true, grants) {
    this.directoryRevision++;
    if (live) this.rosterValidUntil = Date.now() + CERT_LIFETIME_MS;
    const next = /* @__PURE__ */ new Map();
    for (const view of directory) {
      if (!view || typeof view !== "object") continue;
      const c = view.certificate;
      if (!this.options.bindings.verifyCertificate(this.options.client.rootPublicKey, c, c?.issuedAt) || c.networkId !== this.options.client.certificate.networkId || c.subject !== this.options.client.certificate.subject) continue;
      next.set(c.deviceId, view);
      this.knownV2.add(c.deviceId);
    }
    this.roster = next;
    this.keyIndex = null;
    if (grants) {
      this.delegations.clear();
      if (this.options.client.delegation) this.ownDelegation = grants.find((d) => d.scope && delegationVisibleTo(d, this.options.client.identity, this.options.client.delegation) && this.options.bindings.verifyDelegation?.(this.options.client.rootPublicKey, d)) ?? null;
      if (this.options.scoped && !this.options.client.delegation) for (const d of grants) {
        if (d.scope && d.networkId === this.options.client.certificate.networkId && delegationVisibleTo(d, this.options.client.identity) && this.options.bindings.verifyDelegation?.(this.options.client.rootPublicKey, d)) this.delegations.set("guest:" + d.id, d);
      }
      const keys = /* @__PURE__ */ new Map();
      for (const id of this.peerIds()) {
        const k = this.transportKey(id);
        keys.set(k, [...keys.get(k) ?? [], id]);
      }
      for (const ids of keys.values()) if (ids.length > 1) for (const id of ids) this.delegations.delete(id);
      this.keyIndex = null;
      this.options.onDelegations?.(this.options.client.delegation ? this.ownDelegation ? [this.ownDelegation] : [] : [...this.delegations.values()]);
    }
    for (const [id, peer] of this.peers) if (peer.info && next.has(id)) {
      const view = next.get(id);
      peer.info = {
        ...peer.info,
        app: view.app ?? peer.info.app,
        deviceName: view.name,
        selfName: view.selfName ?? peer.info.selfName
      };
      if (this.ready) this.deliver({ v: PROTOCOL_VERSION, kind: "presence-changed", payload: peer.info });
    }
    this.dropUnauthorizedPeers();
    if (live) this.options.onDirectory?.([...next.values()]);
    this.dialRoster();
  }
  dropUnauthorizedPeers() {
    for (const id of this.lanCandidates.keys()) if (!this.authorized(id)) this.lanCandidates.delete(id);
    for (const [id, peer] of this.peers) if (!this.authorized(id) || keyHex(this.transportKey(id)) !== peer.key) {
      this.peers.delete(id);
      peer.channel.close({ drain: false });
      this.presence(id, false);
    }
    for (const [id, queue] of [...this.pending]) if (!this.authorized(id)) {
      this.pending.delete(id);
      for (const item of queue) {
        this.pendingBytes -= item.bytes;
        this.reject(item.frame, "DEVICE_OFFLINE");
      }
    }
  }
  dialRoster() {
    if (this.ready) {
      for (const [id, view] of this.roster) if (!this.peers.has(id)) {
        this.presence(id, false);
        if (view.online && this.deviceId < id && this.memberAccepted(id)) void this.dial(id).catch(() => void 0);
      }
    }
  }
  memberAccepted(deviceId) {
    return !this.peerRule.refused.has(deviceId) && (this.peerRule.allowed === null || this.peerRule.allowed.has(deviceId));
  }
  /**
   * See Transport.networkChanged (the Desktop's network watcher, through the worker; the phone's network events). Without a
   * relay connection, the reconnect may be waiting out a backoff that grew while the old network went away (0.5 s doubling
   * to 15 s): it starts now, as Device Link's client does on a network hint, and an attempt already in flight is kept.
   * Once the relay is back the transport is told again, so what it sent while the relay was down goes out at once.
   */
  networkChanged() {
    if (this.closed) return;
    this.transport?.networkChanged?.();
    if (!this.uplink) this.reconnectRelayNow(false);
  }
  /**
   * This device's own route changed (the phone: Wi-Fi ↔ cellular, lost and back). Besides `networkChanged`, the relay
   * connection is replaced: it may sit half-open on the old route without ever erroring (React Native's WebSocket cannot
   * ping, and this socket answers Device Link's pings itself), while the encrypted connections and their sessions move by
   * themselves and stay. Device Link replaces its own connections on the same evidence. An attempt in flight is kept.
   */
  replaceRelayConnection() {
    if (this.closed) return;
    this.transport?.networkChanged?.();
    const old = this.uplink;
    if (old) {
      this.uplink = null;
      old.close();
      if (this.ready) this.acknowledgeHello();
    }
    this.reconnectRelayNow(!!old);
  }
  /** Connects the relay now instead of after the backoff; without `force` an attempt already in flight is kept. */
  reconnectRelayNow(force) {
    this.resendWhenRelayBack = true;
    if (!force && !this.reconnect) return;
    if (this.reconnect) {
      clearTimeout(this.reconnect);
      this.reconnect = null;
    }
    const attempt = this.connectRelay(), generation = this.generation;
    void attempt.catch(() => {
      if (generation === this.generation && !this.uplink) this.scheduleReconnect();
    });
  }
  /** See Transport.relayRoute (the worker reports it to the Desktop with each status snapshot). */
  relayRoute() {
    return this.closed ? null : this.transport?.relayRoute?.() ?? null;
  }
  /**
   * Which members of this account's directory to accept although their certificates are valid: the host's own membership
   * rule on top of the relay's (the Desktop accepts only devices in the account's Device Link device list, so a device
   * removed there is refused until it signs in again). `allowed` null accepts every member except `refused`. The rule
   * applies as each directory arrives, so a refused device is never dialed or accepted, not even briefly; connections open
   * now that it refuses are closed, and members let back in are dialed again if they are online. Delegated (cross-account)
   * peers are not affected.
   */
  restrictPeers(rule) {
    const next = peerRuleOf(rule);
    const same = (a, b) => a === b || !!a && !!b && a.size === b.size && [...a].every((id) => b.has(id));
    if (same(next.allowed, this.peerRule.allowed) && same(next.refused, this.peerRule.refused)) return;
    this.peerRule = next;
    this.directoryRevision++;
    this.dropUnauthorizedPeers();
    this.dialRoster();
  }
  async connectRelay() {
    const generation = ++this.generation;
    let uplink;
    try {
      uplink = await this.options.client.connect();
    } catch (error) {
      if (/^AGENT_NET_UPGRADE_(401|403)$/.test(error instanceof Error ? error.message : "")) this.close(4410);
      throw error;
    }
    if (this.closed || generation !== this.generation) {
      uplink.close();
      return;
    }
    this.uplink = uplink;
    this.retryMs = 500;
    if (this.resendWhenRelayBack) {
      this.resendWhenRelayBack = false;
      this.transport?.networkChanged?.();
    }
    this.updateDirectory(uplink.devices, true, uplink.delegations ?? []);
    this.options.onDelegationRequests?.(uplink.delegationRequests ?? []);
    uplink.onDatagram((id, data) => this.receiveDatagram?.(id, data));
    uplink.on("directory", () => {
      this.updateDirectory(uplink.devices, true, uplink.delegations ?? []);
      this.options.onDelegationRequests?.(uplink.delegationRequests ?? []);
    });
    uplink.once("close", (code) => {
      if (this.uplink !== uplink || this.closed) return;
      this.uplink = null;
      if ([4410, 4401, 4403].includes(code)) {
        this.close(4410);
        return;
      }
      this.acknowledgeHello();
      this.scheduleReconnect();
    });
    if (this.localHello && !this.options.client.delegation) uplink.presence(this.localHello.remoteControlEnabled, this.localHello.capabilities ?? [], this.localHello);
    if (this.ready) this.acknowledgeHello();
  }
  /** DeviceLinkClient accepts repeated acknowledgements to update capabilities
   * on the same application socket, without resetting authenticated peers. */
  acknowledgeHello() {
    this.deliver({ v: PROTOCOL_VERSION, kind: "hello-ack", payload: {
      serverProtocolVersion: PROTOCOL_VERSION,
      deviceId: this.deviceId,
      userId: this.options.userId,
      capabilities: [
        ...this.uplink?.notifications && this.options.bindings.notify ? [SERVER_CAPABILITY_NOTIFY] : [],
        ...this.options.scoped || this.options.client.delegation?.scope ? [SHARED_TASK_RELAY_CAPABILITY, PROVIDER_SHARE_RELAY_CAPABILITY] : []
      ]
    } });
  }
  scheduleReconnect() {
    if (this.closed || this.reconnect || this.uplink) return;
    this.reconnect = setTimeout(() => {
      this.reconnect = null;
      if (this.uplink) return;
      void this.connectRelay().catch(() => this.scheduleReconnect());
    }, this.retryMs);
    unrefTimer(this.reconnect);
    this.retryMs = Math.min(15e3, this.retryMs * 2);
  }
  send(text2) {
    if (this.closed) throw new Error("AGENT_NET_SOCKET_CLOSED");
    if (utf8(text2).length > MAX_FRAME_BYTES2) throw new Error("PAYLOAD_TOO_LARGE");
    const frame = JSON.parse(text2);
    if (frame.v !== PROTOCOL_VERSION) throw new Error("VERSION_MISMATCH");
    if (!this.ready) {
      if (frame.kind !== "hello") return;
      this.localHello = frame.payload;
      this.ready = true;
      if (!this.options.client.delegation) this.uplink?.presence(this.localHello.remoteControlEnabled, this.localHello.capabilities ?? [], this.localHello);
      this.acknowledgeHello();
      for (const [id, view] of this.roster) if (id !== this.deviceId) {
        this.presence(id, false);
        if (view.online && this.deviceId < id) void this.dial(id).catch(() => void 0);
      }
      for (const peer of this.peers.values()) {
        if (peer.info) this.deliver({ v: PROTOCOL_VERSION, kind: "presence-changed", payload: peer.info });
        this.sendPresence(peer);
      }
      for (const id of this.lanCandidates.keys()) if (!this.peers.has(id)) void this.dial(id).catch(() => void 0);
      return;
    }
    if (frame.kind === "ping") {
      this.deliver({ v: PROTOCOL_VERSION, kind: "pong" });
      return;
    }
    if (frame.kind === "presence-set") {
      this.localHello = { ...this.localHello, ...frame.payload };
      if (!this.options.client.delegation) this.uplink?.presence(this.localHello.remoteControlEnabled, this.localHello.capabilities ?? [], this.localHello);
      for (const peer of this.peers.values()) this.sendPresence(peer);
      return;
    }
    if (frame.kind === "notify") {
      if (this.notifyQueue.length >= NOTIFY_QUEUE_LIMIT) {
        this.reject(frame, "BACKPRESSURE");
        return;
      }
      this.notifyQueue.push(frame);
      if (!this.notifying) void this.drainNotifications();
      return;
    }
    if (!ROUTED_KINDS.has(frame.kind)) return;
    this.route(frame);
  }
  /** Delivers queued pushes in order, one at a time (the relay's push pool is shared by every account). */
  async drainNotifications() {
    this.notifying = true;
    try {
      while (!this.closed && this.notifyQueue.length > 0) await this.notify(this.notifyQueue.shift());
    } finally {
      this.notifying = false;
    }
  }
  async notify(frame) {
    if (!this.uplink?.notifications || !this.options.bindings.notify) return;
    try {
      const payload = frame.payload;
      if (!payload || !["session-done", "session-error", "session-needs-reply"].includes(payload.category) || typeof payload.title !== "string" || typeof payload.deepLink !== "string" || payload.deepLink.length > 512 || typeof payload.collapseId !== "string") throw new Error("INVALID_NOTIFICATION");
      const recipients = [...this.roster.values()].filter((v) => v.notificationKey && this.authorized(v.certificate.deviceId) && (!payload.targetDeviceId || v.certificate.deviceId === payload.targetDeviceId));
      let failed = false;
      for (const recipient of recipients.slice(0, 256)) {
        this.options.assertCurrent?.();
        if (this.closed || this.notificationAbort.signal.aborted) return;
        try {
          await this.options.bindings.notify(recipient, payload, this.notificationAbort.signal, this.options.client);
        } catch {
          failed = true;
        }
      }
      if (failed && !this.closed) this.reject(frame, "NOTIFICATION_DELIVERY_FAILED");
    } catch {
      if (!this.closed) this.reject(frame, "NOTIFICATION_DELIVERY_FAILED");
    }
  }
  route(frame) {
    let id = frame.dst;
    const own = this.ownDelegation;
    if (this.options.client.delegation) {
      const projected = own && scopedFrame(own, frame, "guest", frame.dst);
      if (!projected) {
        this.reject(frame, "FORBIDDEN");
        return;
      }
      frame = projected;
      id = projected.dst;
    } else if (frame.sharedTask !== void 0 || frame.providerShare !== void 0) {
      const match = [...this.delegations].find(([, d]) => this.authorized("guest:" + d.id) && frameMatchesDelegation(d, frame));
      const projected = match && scopedFrame(match[1], frame, "host", this.deviceId);
      if (!match || !projected) {
        this.reject(frame, "FORBIDDEN");
        return;
      }
      id = match[0];
      frame = projected;
    }
    if (!id || !this.authorized(id)) {
      this.reject(frame, "DEVICE_OFFLINE");
      return;
    }
    if (frame.id && ["invoke", "link-open"].includes(frame.kind)) {
      for (const [request, item] of this.sentRequests) if (performance.now() - item.at > 15 * 6e4) this.sentRequests.delete(request);
      if (this.sentRequests.size >= 1e4) {
        this.reject(frame, "BACKPRESSURE");
        return;
      }
      this.sentRequests.set(frame.id, { peer: id, at: performance.now(), frame });
    }
    const peer = this.peers.get(id);
    if (peer) {
      this.write(peer, frame);
      return;
    }
    const bytes = utf8(JSON.stringify(frame)).length;
    const queue = this.pending.get(id) ?? [];
    if (queue.length >= 64 || this.bufferedAmount + bytes > MAX_CHANNEL_PENDING_BYTES) {
      this.reject(frame, "BACKPRESSURE");
      return;
    }
    queue.push({ frame, bytes });
    this.pending.set(id, queue);
    this.pendingBytes += bytes;
    void this.dial(id).catch(() => {
      for (const item of this.pending.get(id) ?? []) {
        this.pendingBytes -= item.bytes;
        this.reject(item.frame, "DEVICE_OFFLINE");
      }
      this.pending.delete(id);
    });
  }
  reject(frame, code) {
    if (frame.id && ["invoke", "link-open"].includes(frame.kind)) this.sentRequests.delete(frame.id);
    this.deliver({
      v: PROTOCOL_VERSION,
      kind: "relay-error",
      ...frame.id ? { id: frame.id } : {},
      ...frame.sharedTask ? { sharedTask: frame.sharedTask } : {},
      ...frame.providerShare ? { providerShare: frame.providerShare } : {},
      payload: { code, message: code, ...frame.dst ? { dst: frame.dst } : {} }
    });
  }
  adopt(channel, outbound) {
    const deviceId = this.deviceForKey(channel.remoteId);
    if (this.closed || !deviceId) {
      channel.close();
      return;
    }
    const previous = this.peers.get(deviceId);
    const preferredOutbound = this.deviceId < deviceId;
    const now2 = performance.now();
    const peerRedialed = previous && !outbound && now2 - previous.since >= REDIAL_TAKEOVER_MS;
    if (previous && previous.outbound !== outbound && outbound !== preferredOutbound && !peerRedialed) {
      channel.close({ drain: false });
      return;
    }
    const peer = { deviceId, key: channel.remoteId, channel, outbound, since: now2 };
    this.peers.set(deviceId, peer);
    previous?.channel.close();
    const frames = new Frames();
    channel.onData((bytes) => {
      const current = this.peers.get(deviceId);
      if (!current || !this.authorized(deviceId) || current !== peer && this.deviceForKey(peer.key) !== deviceId) {
        channel.close();
        return;
      }
      try {
        frames.push(bytes, (frame) => {
          if (this.peers.get(deviceId) !== peer && frame.kind === "presence-changed") return;
          this.fromPeer(peer, frame);
        });
      } catch {
        channel.close();
      }
    });
    channel.onClose(() => {
      const key3 = this.sessionKeys.get(deviceId), attached = key3 === void 0 ? void 0 : this.sessions.get(key3);
      if (attached?.peer === peer) attached.session.dispose("DEVICE_OFFLINE");
      if (this.peers.get(deviceId) !== peer) return;
      this.peers.delete(deviceId);
      this.presence(deviceId, false);
      this.options.onPathChanged?.(deviceId, null);
      if (performance.now() - peer.since >= REDIAL_MAX_MS) this.redialSteps.delete(deviceId);
      this.scheduleRedial(deviceId);
    });
    channel.onDrain?.(() => {
      if (this.peers.get(deviceId) !== peer || !this.drainArmed || this.bufferedAmount > DRAIN_LOW_WATER_BYTES) return;
      this.drainArmed = false;
      this.emit("drain");
    });
    this.attachSession(deviceId, peer);
    this.sendPresence(peer);
    for (const item of this.pending.get(deviceId) ?? []) {
      this.pendingBytes -= item.bytes;
      this.write(peer, item.frame);
    }
    this.pending.delete(deviceId);
    this.options.onPathChanged?.(deviceId, channel.path?.() ?? null);
  }
  /**
   * Where this node's presence goes to a peer: on its session when both declared `SESSION_PRESENCE_FEATURE` (then nothing
   * on this connection is a Device Link frame), otherwise as the Device Link `presence-changed` frame. A peer that may still
   * declare sessions is waited for (`wait`) instead of being sent the frame first.
   */
  presenceRoute(peer) {
    if (peer.presenceFrames || !this.sessionConfig || !peer.channel.declareSessions || this.sessionScope(peer.deviceId)?.role !== "both") return "frame";
    const key3 = this.sessionKeys.get(peer.deviceId), attached = key3 === void 0 ? void 0 : this.sessions.get(key3);
    if (attached?.peer === peer) return peer.channel.sessionFeatures?.().includes(SESSION_PRESENCE_FEATURE) ? "session" : "frame";
    return "wait";
  }
  sendPresence(peer) {
    const route = this.presenceRoute(peer);
    if (route === "wait") {
      if (peer.presenceWait) return;
      peer.presenceWait = setTimeout(() => {
        peer.presenceWait = void 0;
        if (this.closed || this.peers.get(peer.deviceId) !== peer) return;
        if (this.presenceRoute(peer) === "wait") peer.presenceFrames = true;
        this.sendPresence(peer);
      }, PRESENCE_DECLARATION_WAIT_MS);
      unrefTimer(peer.presenceWait);
      return;
    }
    if (route === "session") {
      try {
        this.sessions.get(this.sessionKeys.get(peer.deviceId)).session.presence(this.info());
      } catch {
      }
      return;
    }
    this.write(peer, { v: PROTOCOL_VERSION, kind: "presence-changed", payload: this.info() });
  }
  /** A peer's own presence, from its Device Link frame or its session; names come from the signed directory. */
  peerPresence(peer, value) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return;
    const reported = value, view = this.roster.get(peer.deviceId);
    peer.info = {
      ...reported,
      deviceName: view?.name ?? reported.deviceName,
      selfName: reported.selfName ?? reported.deviceName,
      deviceId: peer.deviceId,
      online: true,
      lastSeenAt: Date.now()
    };
    this.deliver({ v: PROTOCOL_VERSION, kind: "presence-changed", payload: peer.info });
  }
  write(peer, frame) {
    const d = this.options.client.delegation ? this.ownDelegation : this.delegations.get(peer.deviceId);
    if (this.options.client.delegation && !d) return;
    if (d) {
      const projected = scopedFrame(d, frame, this.options.client.delegation ? "guest" : "host", this.options.client.delegation ? peer.deviceId : this.deviceId);
      if (!projected) return;
      frame = projected;
    }
    const body = utf8(JSON.stringify(frame));
    if (body.length > MAX_FRAME_BYTES2) {
      this.reject(frame, "PAYLOAD_TOO_LARGE");
      return;
    }
    if (this.bufferedAmount + body.length + 4 > MAX_CHANNEL_PENDING_BYTES) {
      if (frame.id) this.sentRequests.delete(frame.id);
      this.reject(frame, "BACKPRESSURE");
      return;
    }
    const prefix = new Uint8Array(4);
    new DataView(prefix.buffer).setUint32(0, body.length, false);
    try {
      peer.channel.send(concatBytes([prefix, body]));
      if (this.bufferedAmount > DRAIN_LOW_WATER_BYTES) this.drainArmed = true;
    } catch (error) {
      if (!(error instanceof Error) || !error.message.includes("BACKPRESSURE")) throw error;
      if (frame.id) this.sentRequests.delete(frame.id);
      this.reject(frame, "BACKPRESSURE");
    }
  }
  info() {
    return {
      ...this.localHello,
      deviceId: this.deviceId,
      deviceName: this.localHello?.deviceName ?? "",
      platform: this.localHello?.platform ?? "",
      appVersion: this.localHello?.appVersion ?? "",
      online: true,
      remoteControlEnabled: this.localHello?.remoteControlEnabled ?? false,
      busy: this.localHello?.busy ?? false,
      lastSeenAt: Date.now()
    };
  }
  presence(deviceId, online) {
    if (this.options.client.delegation || this.delegations.has(deviceId) || deviceId.startsWith("guest:")) return;
    if (deviceId === this.deviceId) return;
    const view = this.roster.get(deviceId);
    this.deliver({ v: PROTOCOL_VERSION, kind: "presence-changed", payload: {
      deviceId,
      deviceName: view?.name ?? "",
      selfName: view?.selfName,
      online,
      remoteControlEnabled: online && (view?.remoteControlEnabled ?? false),
      platform: view?.platform ?? "",
      app: view?.app,
      appVersion: view?.appVersion ?? "",
      busy: online && !!view?.busy,
      lastSeenAt: view?.lastSeenAt ?? Date.now()
    } });
  }
  fromPeer(peer, frame) {
    const d = this.options.client.delegation ? this.ownDelegation : this.delegations.get(peer.deviceId);
    if (this.options.client.delegation && !d) return;
    if (d && frame.kind === "presence-changed") return;
    if (frame.kind === "presence-changed") {
      const reported = frame.payload, view = this.roster.get(peer.deviceId);
      peer.info = {
        ...reported,
        app: reported.app ?? view?.app ?? peer.info?.app,
        deviceName: view?.name ?? reported.deviceName,
        selfName: reported.selfName ?? reported.deviceName,
        deviceId: peer.deviceId,
        online: true,
        lastSeenAt: Date.now()
      };
      this.deliver({ ...frame, payload: peer.info });
      return;
    }
    if (frame.kind === "relay-error") {
      const request = frame.id && this.sentRequests.get(frame.id);
      if (!request || request.peer !== peer.deviceId) return;
      this.deliver({
        ...frame,
        sharedTask: request.frame.sharedTask,
        providerShare: request.frame.providerShare,
        src: peer.deviceId,
        payload: { ...frame.payload, dst: request.frame.dst }
      });
      return;
    }
    if (d) {
      const projected = scopedFrame(d, frame, this.options.client.delegation ? "host" : "guest", this.options.client.delegation ? peer.deviceId : this.deviceId);
      if (!projected) return;
      if (frame.id && ["invoke-result", "link-accept"].includes(frame.kind)) this.sentRequests.delete(frame.id);
      this.deliver(projected);
      return;
    }
    if (frame.sharedTask !== void 0 || frame.providerShare !== void 0) return;
    if (!ROUTED_KINDS.has(frame.kind) || frame.dst !== this.deviceId) return;
    if (CONTROL_KINDS.has(frame.kind) && !this.localHello?.remoteControlEnabled) {
      this.write(peer, { v: PROTOCOL_VERSION, kind: "relay-error", id: frame.id, payload: {
        code: "REMOTE_DISABLED",
        message: "REMOTE_DISABLED",
        dst: this.deviceId
      } });
      return;
    }
    if (frame.id && ["invoke-result", "link-accept"].includes(frame.kind)) this.sentRequests.delete(frame.id);
    this.deliver({ ...frame, src: peer.deviceId });
  }
  deliver(frame) {
    if (!this.closed && this.ready) this.emit("message", { toString: () => JSON.stringify(frame) });
  }
  close(code = 1e3) {
    if (this.closed) return;
    this.closed = true;
    this.generation++;
    this.notificationAbort.abort();
    this.notifyQueue = [];
    for (const timer of this.redials.values()) clearTimeout(timer);
    this.redials.clear();
    this.lan?.close();
    this.lan = null;
    this.lanCandidates.clear();
    if (this.directoryRefresh) clearInterval(this.directoryRefresh);
    this.directoryRefresh = void 0;
    if (this.reconnect) clearTimeout(this.reconnect);
    this.reconnect = null;
    this.uplink?.close();
    this.uplink = null;
    for (const peer of this.peers.values()) {
      if (peer.presenceWait) clearTimeout(peer.presenceWait);
      peer.channel.close();
    }
    this.peers.clear();
    this.pending.clear();
    this.pendingBytes = 0;
    this.sentRequests.clear();
    const transportClosed = this.transport?.close().catch(() => void 0) ?? Promise.resolve();
    void transportClosed.then(() => this.emit("close", code, ""));
  }
  terminate() {
    this.close(1006);
  }
};

// ../../packages/agent-net/src/portableClient.ts
var UDP_RELAY_HEADER = "x-agent-net-udp";
var UDP_RELAY_VERSION = "2";
function udpCredentialsAllowed(wsUrl) {
  return /^wss:\/\//i.test(wsUrl) || /^ws:\/\/(127\.0\.0\.1|localhost|\[::1\])(:\d+)?(\/|$)/i.test(wsUrl);
}
function udpCredentials(value) {
  if (!value || typeof value !== "object") return null;
  const { session, key: key3 } = value;
  if (typeof session !== "string" || typeof key3 !== "string") return null;
  try {
    const credentials = { session: fromBase64Url(session), key: fromBase64Url(key3) };
    return credentials.session.length === 8 && credentials.key.length === 32 ? credentials : null;
  } catch {
    return null;
  }
}
var PortableAgentNetClientError = class extends Error {
  constructor(status, code) {
    super(code);
    __publicField(this, "status", status);
    __publicField(this, "code", code);
  }
};
var STORAGE_UNREACHABLE = /* @__PURE__ */ Symbol("storage unreachable");
var DIRECT_STORAGE_RETRY_MS = 10 * 6e4;
var PortableAgentNetClient = class {
  constructor(base, signer, certificate, rootPublicKey, options) {
    __publicField(this, "signer", signer);
    __publicField(this, "rootPublicKey", rootPublicKey);
    __publicField(this, "options", options);
    __publicField(this, "base");
    __publicField(this, "identity");
    __publicField(this, "activeCertificate");
    /** Uploads the relay granted direct transfer for (until complete). */
    __publicField(this, "directUploads", /* @__PURE__ */ new Set());
    /** Presigned storage reads, reused until shortly before they expire. */
    __publicField(this, "directReads", /* @__PURE__ */ new Map());
    /** Until then this client's network could not reach the storage, so media goes through the relay. */
    __publicField(this, "directUnreachableUntil", 0);
    const url = new URL(base);
    if (url.username || url.password || url.search || url.hash || url.protocol !== "https:" && !(url.protocol === "http:" && (options.ownerPinnedHttp || ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)))) {
      throw new Error("SECURE_AGENT_NET_URL_REQUIRED");
    }
    this.base = stripTrailingSlashes(base);
    this.identity = signer.identity;
    const d = options.delegation;
    if (!options.verifyCertificate(rootPublicKey, certificate) || !d && (certificate.deviceId !== this.identity.deviceId || certificate.signingKey !== this.identity.signingKey || certificate.transportKey !== this.identity.transportKey) || d && (!options.verifyDelegation?.(rootPublicKey, d) || d.guestDeviceId !== this.identity.deviceId || d.guestSigningKey !== this.identity.signingKey || d.guestTransportKey !== this.identity.transportKey || d.issuerCertificate.signature !== certificate.signature)) {
      throw new Error("IDENTITY_CERTIFICATE_MISMATCH");
    }
    this.activeCertificate = Object.freeze({ ...certificate });
  }
  get delegation() {
    return this.options.delegation;
  }
  get certificate() {
    return this.activeCertificate;
  }
  /** Refresh only a certificate/signer for the very same principal. Existing
   * media requests retain this API object and continue with fresh credentials. */
  replaceCredentials(signer, certificate) {
    this.options.assertCurrent();
    if (!this.options.verifyCertificate(this.rootPublicKey, certificate) || certificate.networkId !== this.certificate.networkId || certificate.subject !== this.certificate.subject || certificate.deviceId !== this.identity.deviceId || certificate.signingKey !== this.identity.signingKey || certificate.transportKey !== this.identity.transportKey || signer.identity.deviceId !== this.identity.deviceId || signer.identity.signingKey !== this.identity.signingKey || signer.identity.transportKey !== this.identity.transportKey) {
      throw new Error("AGENT_NET_IDENTITY_CHANGED");
    }
    this.signer = signer;
    this.activeCertificate = Object.freeze({ ...certificate });
  }
  path(resource) {
    return "/api/agent-net" + (this.delegation ? "/guest" : "") + resource;
  }
  async header(method, path, body = "") {
    this.options.assertCurrent();
    const entropy = await this.signer.random();
    this.options.assertCurrent();
    if (fromBase64Url(entropy).length < 18) throw new Error("INVALID_NATIVE_RANDOM");
    const plain = { at: Date.now(), nonce: entropy.slice(0, 24) };
    const hash = this.options.sha256(typeof body === "string" ? utf8(body) : body);
    const signature = await this.signer.sign(requestPayload(method, this.delegation ? guestRequestPath(path, this.delegation.networkId, this.delegation.id) : path, hash, plain));
    this.options.assertCurrent();
    return (this.delegation ? "AgentNetGuest " : "AgentNet ") + toBase64Url(utf8(JSON.stringify({
      ...this.delegation ? { networkId: this.delegation.networkId, delegationId: this.delegation.id } : { certificate: this.certificate },
      proof: { ...plain, signature }
    })));
  }
  async request(method, resource, input, options) {
    const path = this.path(resource), body = input === void 0 ? "" : JSON.stringify(input);
    const authorization = await this.header(method, path, body);
    this.options.assertCurrent();
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 1e4);
    const abort = () => controller.abort();
    if (options?.signal?.aborted) controller.abort();
    else options?.signal?.addEventListener("abort", abort, { once: true });
    const readTransport = async (read, status) => {
      try {
        return await read();
      } catch (error) {
        this.options.assertCurrent();
        if (!options?.signal?.aborted) {
          if (status && status >= 400) throw new PortableAgentNetClientError(status, "AGENT_NET_REQUEST_FAILED");
          if (controller.signal.aborted) throw new PortableAgentNetClientError(0, "AGENT_NET_REQUEST_TIMEOUT");
          if (error instanceof TypeError || error?.name === "AbortError") {
            throw new PortableAgentNetClientError(0, "AGENT_NET_NETWORK_ERROR");
          }
        }
        throw error;
      }
    };
    try {
      const response = await readTransport(() => (this.options.fetch ?? fetch)(this.base + path, {
        method,
        headers: { authorization, ...body ? { "content-type": "application/json" } : {} },
        ...body ? { body } : {},
        redirect: "error",
        signal: controller.signal
      }));
      this.options.assertCurrent();
      const result = await readTransport(() => response.json(), response.status);
      this.options.assertCurrent();
      if (!response.ok) throw new PortableAgentNetClientError(
        response.status,
        typeof result.error?.code === "string" && /^[A-Z0-9_]{1,80}$/.test(result.error.code) ? result.error.code : "AGENT_NET_REQUEST_FAILED"
      );
      return result;
    } finally {
      clearTimeout(timer);
      options?.signal?.removeEventListener("abort", abort);
    }
  }
  trustedDirectory(devices, delegations, requests = []) {
    return devices.every((view) => {
      const c = view?.certificate;
      return c && this.options.verifyCertificate(this.rootPublicKey, c, c.issuedAt) && c.issuedAt <= Date.now() + 3e4 && c.networkId === this.certificate.networkId && c.subject === this.certificate.subject;
    }) && delegations.every((delegation) => this.options.verifyDelegation?.(this.rootPublicKey, delegation) && delegation.networkId === this.certificate.networkId && delegationVisibleTo(delegation, this.identity, this.delegation)) && requests.length <= 128 && (!this.delegation || requests.length === 0) && requests.every((request) => delegationRequestPolicyValid(request, this.certificate));
  }
  /**
   * Read the encrypted directory. `signal` carries the caller's own deadline so a
   * bounded read does not leave this request running past it: the next retry would
   * otherwise start a second physical directory read while this one is still in
   * flight (Codex review #9360).
   */
  async directory(signal) {
    const result = await this.request("GET", "/directory", void 0, signal ? { signal } : void 0);
    if (result.rootPublicKey !== this.rootPublicKey || !Array.isArray(result.devices) || !this.trustedDirectory(result.devices, [])) {
      throw new Error("UNTRUSTED_DIRECTORY");
    }
    return result.devices;
  }
  async mediaRequest(method, resource, consume, body, range2, signal, extraHeaders = {}) {
    const path = this.path(resource), authorization = await this.header(method, path, body);
    this.options.assertCurrent();
    const controller = new AbortController();
    let timer = setTimeout(() => controller.abort(), 6e4);
    const onByteProgress = (bytes) => {
      if (controller.signal.aborted || !Number.isFinite(bytes) || bytes <= 0) return;
      clearTimeout(timer);
      timer = setTimeout(() => controller.abort(), 6e4);
    };
    const abort = () => controller.abort();
    if (signal?.aborted) controller.abort();
    else signal?.addEventListener("abort", abort, { once: true });
    try {
      const response = await (this.options.fetch ?? fetch)(this.base + path, { method, headers: {
        authorization,
        ...body ? { "content-type": "application/octet-stream", "x-agent-net-content-sha256": this.options.sha256(body) } : {},
        ...range2 ? { range: range2 } : {},
        ...extraHeaders
      }, ...body ? { body: new Uint8Array(body) } : {}, redirect: "error", signal: controller.signal });
      this.options.assertCurrent();
      if (!response.ok) throw new PortableAgentNetClientError(response.status, "AGENT_NET_MEDIA_REQUEST_FAILED");
      const result = await consume(response, onByteProgress);
      this.options.assertCurrent();
      return result;
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      controller.abort();
    }
  }
  /**
   * Starts an encrypted upload, offering direct transfer when an MD5 digest is available. A relay whose storage
   * clients can reach grants it and the chunks go to the storage itself; any other relay ignores the offer.
   */
  async createMedia(recipient, size, signal) {
    const created = await this.request("POST", "/media", {
      recipient,
      size,
      chunkFormat: "binary-v1",
      ...this.options.md5 && this.directReachable() ? { transfer: MEDIA_TRANSFER_DIRECT } : {}
    }, { signal });
    if (created.transfer === MEDIA_TRANSFER_DIRECT && this.options.md5) {
      if (this.directUploads.size >= 64) this.directUploads.delete(this.directUploads.values().next().value);
      this.directUploads.add(created.id);
    }
    return { id: created.id, chunkBytes: created.chunkBytes };
  }
  directReachable() {
    return Date.now() >= this.directUnreachableUntil;
  }
  /** A network that reaches the relay but not the storage (a firewall that allows only the relay, say) keeps
   * working through the relay, which reads and writes the same storage. */
  directUnreachable() {
    this.directUnreachableUntil = Date.now() + DIRECT_STORAGE_RETRY_MS;
    this.directReads.clear();
  }
  /** A storage request from the relay; plain HTTP only when the relay itself is reached over plain HTTP. */
  directRequest(value) {
    if (!directMediaRequestValid(value)) throw new Error("INVALID_DIRECT_MEDIA_REQUEST");
    if (new URL(value.url).protocol !== "https:" && new URL(this.base).protocol !== "http:") throw new Error("INSECURE_DIRECT_MEDIA_REQUEST");
    return value;
  }
  /** One storage request under the same deadline/cancellation rules as relay media requests. */
  async storageRequest(target, consume, body, range2, signal) {
    this.options.assertCurrent();
    const controller = new AbortController();
    let timer = setTimeout(() => controller.abort(), 6e4);
    const onByteProgress = (bytes) => {
      if (controller.signal.aborted || !Number.isFinite(bytes) || bytes <= 0) return;
      clearTimeout(timer);
      timer = setTimeout(() => controller.abort(), 6e4);
    };
    const abort = () => controller.abort();
    if (signal?.aborted) controller.abort();
    else signal?.addEventListener("abort", abort, { once: true });
    try {
      let response;
      try {
        response = await (this.options.fetch ?? fetch)(target.url, {
          method: target.method,
          headers: { ...target.headers, ...range2 ? { range: range2 } : {} },
          ...body ? { body: new Uint8Array(body) } : {},
          redirect: "error",
          signal: controller.signal
        });
      } catch (error) {
        if (signal?.aborted) throw error;
        this.options.assertCurrent();
        return STORAGE_UNREACHABLE;
      }
      this.options.assertCurrent();
      const result = await consume(response, onByteProgress);
      this.options.assertCurrent();
      return result;
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      controller.abort();
    }
  }
  async putDirectMediaChunk(id, offset, body, signal) {
    const resource = "/media/" + encodeURIComponent(id);
    const md5 = toBase64Url(this.options.md5(body)).replace(/-/g, "+").replace(/_/g, "/") + "==";
    const target = this.directRequest((await this.request("POST", resource + "/upload", { offset, size: body.length, md5 }, { signal })).request);
    let rejected, unreachable = false;
    try {
      const stored = await this.storageRequest(target, async (response) => {
        await response.body?.cancel().catch(() => void 0);
        return response.ok ? void 0 : response.status;
      }, body, void 0, signal);
      if (stored === STORAGE_UNREACHABLE) unreachable = true;
      else rejected = stored;
    } catch (error) {
      if (signal?.aborted) throw error;
      this.options.assertCurrent();
    }
    const result = await this.request("POST", resource + "/commit", void 0, { signal });
    if (unreachable && result.received === offset) {
      this.directUploads.delete(id);
      this.directUnreachable();
      return this.putMediaChunk(id, offset, body, signal);
    }
    if (result.received !== offset + body.length) throw new PortableAgentNetClientError(rejected ?? 0, rejected ? "MEDIA_STORAGE_REJECTED" : "MEDIA_OFFSET_MISMATCH");
    if (result.complete) this.directUploads.delete(id);
    return result;
  }
  async putMediaChunk(id, offset, body, signal) {
    if (!Number.isSafeInteger(offset) || offset < 0 || body.length < 1 || body.length > MAX_MEDIA_BINARY_CHUNK_BYTES) throw new Error("INVALID_MEDIA_CHUNK");
    if (this.directUploads.has(id)) return this.putDirectMediaChunk(id, offset, body, signal);
    return this.mediaRequest(
      "PUT",
      "/media/" + encodeURIComponent(id) + "?offset=" + offset,
      (response) => response.json(),
      body,
      void 0,
      signal
    );
  }
  /** Consume the body within this scope so abort/timeout outlive the headers. */
  async withMediaResponse(id, range2, consume, signal) {
    const refused = /* @__PURE__ */ Symbol("refused");
    const fromStorage = (target) => this.storageRequest(target, async (response, onByteProgress) => {
      if (response.status === 403) {
        await response.body?.cancel().catch(() => void 0);
        return refused;
      }
      if (!response.ok && response.status !== 206) {
        await response.body?.cancel().catch(() => void 0);
        throw new PortableAgentNetClientError(response.status, "MEDIA_STORAGE_READ_FAILED");
      }
      return consume(response, onByteProgress);
    }, void 0, range2, signal);
    const cached = this.directReachable() ? this.directReads.get(id) : void 0;
    if (cached && cached.until > Date.now()) {
      const result2 = await fromStorage(cached.request);
      if (result2 !== refused && result2 !== STORAGE_UNREACHABLE) return result2;
      if (result2 === STORAGE_UNREACHABLE) this.directUnreachable();
      else this.directReads.delete(id);
    }
    const direct = this.directReachable();
    const granted = await this.mediaRequest("GET", "/media/" + encodeURIComponent(id), async (response, onByteProgress) => {
      if (response.headers.get(MEDIA_TRANSFER_HEADER) !== MEDIA_TRANSFER_DIRECT) return { relayed: await consume(response, onByteProgress) };
      return { target: this.directRequest((await response.json()).request) };
    }, void 0, range2, signal, direct ? { [MEDIA_TRANSFER_HEADER]: MEDIA_TRANSFER_DIRECT } : {});
    if ("relayed" in granted) return granted.relayed;
    if (this.directReads.size >= 64) this.directReads.delete(this.directReads.keys().next().value);
    this.directReads.set(id, { request: granted.target, until: Math.min(granted.target.expiresAt - 3e4, Date.now() + 10 * 6e4) });
    const result = await fromStorage(granted.target);
    if (result === STORAGE_UNREACHABLE) {
      this.directUnreachable();
      return this.withMediaResponse(id, range2, consume, signal);
    }
    if (result === refused) throw new PortableAgentNetClientError(403, "MEDIA_STORAGE_READ_FAILED");
    return result;
  }
  async connect() {
    const path = this.path("/ws"), header = await this.header("GET", path);
    this.options.assertCurrent();
    const url = this.base.replace(/^http/, "ws") + path, askUdp = this.options.relayUdpEnabled?.() === true && udpCredentialsAllowed(url);
    const ws = this.options.createWebSocket(url, { authorization: header, ...askUdp ? { [UDP_RELAY_HEADER]: UDP_RELAY_VERSION } : {} });
    ws.binaryType = "arraybuffer";
    return PortableUplink.open(ws, this, askUdp);
  }
};
var PortableUplink = class _PortableUplink extends SocketEvents {
  constructor(ws) {
    super();
    __publicField(this, "ws", ws);
    __publicField(this, "kind", "agent-net");
    __publicField(this, "devices", []);
    __publicField(this, "delegations", []);
    __publicField(this, "delegationRequests", []);
    __publicField(this, "notifications", false);
    /** This session's relay UDP credentials when the relay offered them; null keeps every relayed datagram on the WebSocket. */
    __publicField(this, "udp", null);
    __publicField(this, "receiver", null);
    __publicField(this, "pending", []);
    __publicField(this, "pendingBytes", 0);
    __publicField(this, "queues", /* @__PURE__ */ new Map());
    __publicField(this, "queuedBytes", 0);
    __publicField(this, "scheduled", null);
    __publicField(this, "closed", false);
  }
  static open(ws, client, askUdp = false) {
    const uplink = new _PortableUplink(ws);
    return new Promise((resolve, reject) => {
      let established = false, receivedHello = false;
      const timer = setTimeout(() => fail(new Error("AGENT_NET_HANDSHAKE_TIMEOUT")), 1e4);
      const fail = (error) => {
        clearTimeout(timer);
        if (!established) reject(error);
        uplink.close();
      };
      let chain = Promise.resolve(), waiting = 0;
      ws.onerror = (event) => {
        const status = typeof event.message === "string" ? /\b(401|403)\b/.exec(event.message)?.[1] : void 0;
        fail(new Error(status ? "AGENT_NET_UPGRADE_" + status : "AGENT_NET_SOCKET_ERROR"));
      };
      ws.onclose = (event) => {
        clearTimeout(timer);
        if (!established) reject(new Error("AGENT_NET_CLOSED_" + event.code));
        uplink.closed = true;
        uplink.emit("close", event.code);
      };
      ws.onmessage = (event) => {
        if (uplink.closed) return;
        if (++waiting > 512) {
          fail(new Error("AGENT_NET_RECEIVE_BACKPRESSURE"));
          return;
        }
        const receive = async () => {
          if (uplink.closed) return;
          client.options.assertCurrent();
          if (typeof event.data === "string") {
            if (utf8(event.data).length > MAX_CONTROL_BYTES) throw new Error("INVALID_CONTROL");
            const message = JSON.parse(event.data);
            const requests = message.delegationRequests ?? [];
            if (!["hello", "directory"].includes(message.type) || !Array.isArray(message.devices) || !Array.isArray(message.delegations) || !Array.isArray(requests) || !client.trustedDirectory(message.devices, message.delegations, requests)) throw new Error("UNTRUSTED_DIRECTORY");
            uplink.devices = message.devices;
            uplink.delegations = message.delegations;
            uplink.delegationRequests = requests;
            if (message.type === "hello") {
              if (receivedHello || message.protocolVersion !== 2 || message.deviceId !== (client.delegation ? "guest:" + client.delegation.id : client.identity.deviceId)) throw new Error("INVALID_HELLO");
              uplink.notifications = message.notifications === true;
              uplink.udp = askUdp ? udpCredentials(message.udp) : null;
              receivedHello = true;
              established = true;
              clearTimeout(timer);
              resolve(uplink);
            } else {
              if (!receivedHello) throw new Error("INVALID_HELLO");
              uplink.emit("directory");
            }
            return;
          }
          if (!receivedHello) throw new Error("INVALID_HELLO");
          let bytes;
          if (event.data instanceof ArrayBuffer) bytes = new Uint8Array(event.data);
          else if (ArrayBuffer.isView(event.data)) bytes = new Uint8Array(event.data.buffer, event.data.byteOffset, event.data.byteLength);
          else throw new Error("INVALID_DATAGRAM_FRAME");
          const frame = decodeDatagrams(bytes);
          if (!frame) throw new Error("INVALID_DATAGRAM_FRAME");
          for (const packet of frame.datagrams) {
            if (uplink.receiver) uplink.receiver(frame.deviceId, packet);
            else {
              if (uplink.pending.length >= 512 || uplink.pendingBytes + packet.length > 1024 * 1024) throw new Error("AGENT_NET_RECEIVE_BACKPRESSURE");
              uplink.pending.push([frame.deviceId, packet.slice()]);
              uplink.pendingBytes += packet.length;
            }
          }
        };
        chain = chain.then(receive).catch((error) => fail(error instanceof Error ? error : new Error("INVALID_CONTROL"))).finally(() => {
          waiting--;
        });
      };
    });
  }
  onDatagram(receiver) {
    this.receiver = receiver;
    for (const [id, data] of this.pending) receiver(id, data);
    this.pending = [];
    this.pendingBytes = 0;
  }
  send(deviceId, data) {
    if (this.closed || this.ws.readyState !== 1 || !data.length || data.length > 65e3 || this.queuedBytes + data.length > 1024 * 1024 || this.queues.size >= 256) return;
    const packets = this.queues.get(deviceId) ?? [];
    packets.push(data.slice());
    this.queues.set(deviceId, packets);
    this.queuedBytes += data.length;
    if (this.scheduled) return;
    this.scheduled = setTimeout(() => {
      this.scheduled = null;
      const queues = this.queues;
      this.queues = /* @__PURE__ */ new Map();
      this.queuedBytes = 0;
      for (const [id, packets2] of queues) {
        let batch = [], size = 2 + id.length;
        const flush = () => {
          if (batch.length && !this.closed && this.ws.readyState === 1 && this.ws.bufferedAmount <= 1024 * 1024) {
            try {
              this.ws.send(encodeDatagrams(id, batch));
            } catch {
            }
          }
          batch = [];
          size = 2 + id.length;
        };
        for (const packet of packets2) {
          if (size + 2 + packet.length > MAX_FRAME_BYTES) flush();
          batch.push(packet);
          size += packet.length + 2;
        }
        flush();
      }
    }, 0);
  }
  presence(remoteControlEnabled, capabilities, metadata = {}) {
    if (!this.closed && this.ws.readyState === 1) this.ws.send(JSON.stringify({
      type: "presence",
      remoteControlEnabled,
      capabilities,
      platform: metadata.platform,
      app: metadata.app,
      appVersion: metadata.appVersion,
      busy: metadata.busy,
      deviceName: metadata.deviceName
    }));
  }
  close() {
    if (this.closed) return;
    this.closed = true;
    if (this.scheduled) clearTimeout(this.scheduled);
    this.scheduled = null;
    this.pending = [];
    this.pendingBytes = 0;
    this.queues.clear();
    this.queuedBytes = 0;
    this.ws.close();
  }
};

// ../../packages/agent-net/src/nativeTransport.ts
var MAX_PENDING = 16 * 1024 * 1024;
var MAX_CANDIDATES = 16;
var MAX_STUN_SERVERS = 4;
var DATA = 68;
var CONTROL = 67;
var LANE_BY_KIND = new Map(Object.entries(SESSION_LANE_KINDS).map(([lane, kind]) => [kind, lane]));
var WRITES_PER_STREAM = 8;
var WRITE_CHUNK = 65536;
var FAST_POLL_MS = 8;
var IDLE_POLL_MS = 50;
var ACTIVE_WINDOW_MS = 1e3;
var now = () => performance.now();
var NativeTransport = class _NativeTransport {
  constructor(engine, options, identity, addresses, readAddresses, enhanced) {
    __publicField(this, "engine", engine);
    __publicField(this, "options", options);
    __publicField(this, "identity", identity);
    __publicField(this, "readAddresses", readAddresses);
    __publicField(this, "enhanced", enhanced);
    __publicField(this, "id");
    __publicField(this, "dial");
    __publicField(this, "closed", false);
    __publicField(this, "timer", null);
    /** The delay the pending poll was scheduled with. */
    __publicField(this, "timerDelay", 0);
    /** Poll fast until then (a new transport starts out connecting). */
    __publicField(this, "activeUntil", now() + ACTIVE_WINDOW_MS);
    __publicField(this, "channels", /* @__PURE__ */ new Map());
    __publicField(this, "waiting", /* @__PURE__ */ new Map());
    __publicField(this, "links", /* @__PURE__ */ new Map());
    __publicField(this, "deviceForLink", /* @__PURE__ */ new Map());
    __publicField(this, "lastAdmission", "");
    __publicField(this, "nextLink", 0);
    __publicField(this, "pendingBytes", 0);
    __publicField(this, "features");
    __publicField(this, "localAddresses");
    __publicField(this, "mapped", []);
    __publicField(this, "candidateList", []);
    /** The relay UDP credentials last given to the engine (`undefined`: none given yet). */
    __publicField(this, "relayCredentials");
    __publicField(this, "relayUdpUp", false);
    __publicField(this, "relayUdpServer");
    __publicField(this, "refreshingAddresses", false);
    this.id = keyHex(identity.transportKey);
    this.dial = identity.udpPort ? { udp: { address: "0.0.0.0", port: identity.udpPort } } : {};
    this.features = new Set(Array.isArray(identity.features) ? identity.features : []);
    this.relayUdpServer = options.relayUdpServer;
    this.localAddresses = addresses;
    this.candidateList = this.computeCandidates();
    options.relay?.uplink.onDatagram((deviceId, bytes) => {
      if (this.closed) return;
      const link = this.links.get(deviceId);
      if (!link) return;
      void this.call({ op: "datagram", from: { link }, data: toBase64Url(bytes) }).catch(() => void 0);
      this.wake();
    });
  }
  static async create(engine, options, addresses = [], enhanced = true) {
    if (!options.admittedPeers) throw new Error("NATIVE_PEER_LIST_REQUIRED");
    try {
      const identity = await engine.command({ op: "identity" });
      const read = typeof addresses === "function" ? addresses : null;
      const initial = typeof addresses === "function" ? await addresses().catch(() => []) : addresses;
      const transport = new _NativeTransport(engine, options, identity, initial, enhanced ? read : null, enhanced);
      await transport.synchronizeAdmission();
      await transport.startStun();
      transport.schedule();
      return transport;
    } catch (error) {
      await engine.destroy().catch(() => void 0);
      throw error;
    }
  }
  async call(command) {
    if (this.closed) throw new Error("NATIVE_TRANSPORT_CLOSED");
    this.engine.assertCurrent?.();
    const result = await this.engine.command(command);
    this.engine.assertCurrent?.();
    if (this.closed) throw new Error("NATIVE_TRANSPORT_CLOSED");
    return result;
  }
  supports(feature) {
    return this.features.has(feature);
  }
  /** Relayed datagrams go over UDP right now (both directions acknowledged by the relay). */
  get relayOverUdp() {
    return this.relayUdpUp;
  }
  /** Local addresses and STUN answers, public first, as the Desktop driver orders them. */
  candidates() {
    return this.candidateList;
  }
  computeCandidates() {
    const port = this.identity.udpPort;
    if (!port) return [];
    const local = this.localAddresses.filter((address) => address.length <= 128).map((address) => ({ address, port }));
    if (!this.enhanced) return local.slice(0, MAX_CANDIDATES);
    const seen = /* @__PURE__ */ new Set();
    return [...local, ...this.mapped].filter((candidate) => {
      const key3 = `${candidate.address}:${candidate.port}`;
      if (seen.has(key3)) return false;
      seen.add(key3);
      return true;
    }).sort((a, b) => Number(isPrivate(a.address)) - Number(isPrivate(b.address))).slice(0, MAX_CANDIDATES);
  }
  updateCandidates() {
    const next = this.computeCandidates();
    if (JSON.stringify(next) === JSON.stringify(this.candidateList)) return;
    this.candidateList = next;
    for (const channel of this.channels.values()) channel.announceCandidates();
  }
  async configureUdpServer(server) {
    if (this.closed || !this.enhanced) return;
    this.relayUdpServer = server;
    await this.startStun([server]);
  }
  async startStun(servers = (this.options.stunServers ?? []).slice(0, MAX_STUN_SERVERS)) {
    if (!servers.length || !this.identity.udpPort || !this.supports("stun")) return;
    await this.call({ op: "stun", servers }).catch(() => void 0);
  }
  /**
   * The relay's UDP path follows the relay WebSocket's session: new credentials on every reconnect, none when it offered
   * none (an older relay, plain http). Until the relay acknowledges a registration, datagrams stay on the WebSocket.
   */
  async synchronizeRelayUdp() {
    const server = this.relayUdpServer, read = this.options.relay?.udpCredentials;
    if (!server || !read || !this.identity.udpPort || !this.supports("relay-udp-v2")) return;
    const credentials = read() ?? null;
    if (credentials === this.relayCredentials) return;
    this.relayCredentials = credentials;
    await this.call({ op: "relayUdp", server, ...credentials ? { session: toBase64Url(credentials.session), key: toBase64Url(credentials.key) } : { session: null } });
  }
  linkFor(deviceId) {
    const existing = this.links.get(deviceId);
    if (existing) return existing;
    if (this.links.size >= 4096) throw new Error("NATIVE_PEER_ADDRESS_LIMIT");
    const link = ++this.nextLink;
    this.links.set(deviceId, link);
    this.deviceForLink.set(link, deviceId);
    return link;
  }
  async synchronizeAdmission() {
    const entries = this.options.admittedPeers().map((peer) => {
      if (!/^[a-f0-9]{64}$/.test(peer.id) || !this.options.admit(peer.id)) throw new Error("INVALID_NATIVE_PEER");
      const key3 = Uint8Array.from(peer.id.match(/../g), (part) => parseInt(part, 16));
      return { key: toBase64Url(key3), link: this.linkFor(peer.relayId), ...this.enhanced ? { relayId: peer.relayId } : {} };
    }).sort((a, b) => a.link - b.link);
    const serialized = JSON.stringify(entries);
    if (serialized === this.lastAdmission) return;
    await this.call({ op: "admit", peers: entries });
    this.lastAdmission = serialized;
  }
  async connect(entry) {
    if (!this.options.admit(entry.id)) throw new Error("UNAUTHORIZED_PEER");
    await this.synchronizeAdmission();
    const dial = entry.dial;
    const expected = this.options.relayIdOf?.(entry.id);
    if (!expected || dial.relayId !== expected) throw new Error("PEER_ADDRESS_MISMATCH");
    const address = dial.preferUdp && dial.udp ? dial.udp : { link: this.linkFor(expected) };
    const key3 = toBase64Url(Uint8Array.from(entry.id.match(/../g), (part) => parseInt(part, 16)));
    const id = await this.call({ op: "connect", key: key3, address });
    return new Promise((resolve, reject) => {
      if (this.closed) {
        reject(new Error("NATIVE_TRANSPORT_CLOSED"));
        return;
      }
      this.waiting.set(id, { resolve, reject, deadline: now() + 3e3 });
      this.wake();
    });
  }
  /**
   * The phone changed networks: connections send from the new address now (the peer follows), STUN asks again, and the
   * local addresses are read again for the candidates.
   */
  networkChanged() {
    if (this.closed || !this.enhanced) return;
    void this.call({ op: "migrate" }).catch(() => void 0);
    this.wake();
    if (!this.readAddresses || this.refreshingAddresses) return;
    this.refreshingAddresses = true;
    void this.readAddresses().then((addresses) => {
      if (this.closed) return;
      this.localAddresses = addresses;
      this.updateCandidates();
    }).catch(() => void 0).finally(() => {
      this.refreshingAddresses = false;
    });
  }
  reserve(bytes) {
    if (this.pendingBytes + bytes > MAX_PENDING) throw new Error("NATIVE_TRANSPORT_BACKPRESSURE");
    this.pendingBytes += bytes;
  }
  release(bytes) {
    this.pendingBytes = Math.max(0, this.pendingBytes - bytes);
  }
  schedule(delay = now() < this.activeUntil ? FAST_POLL_MS : IDLE_POLL_MS) {
    if (this.closed || this.timer) return;
    this.timerDelay = delay;
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.poll().then(() => this.schedule(), () => this.close());
    }, delay);
  }
  /**
   * Something to move: poll fast for a while, and at once if the next poll was an idle one. A poll under way is left alone;
   * the next follows FAST_POLL_MS after it, as it always did.
   */
  wake() {
    this.activeUntil = now() + ACTIVE_WINDOW_MS;
    if (this.closed || !this.timer || this.timerDelay <= FAST_POLL_MS) return;
    clearTimeout(this.timer);
    this.timer = null;
    this.schedule(0);
  }
  async poll() {
    await this.synchronizeAdmission();
    await this.synchronizeRelayUdp();
    const waitingAtPoll = new Map(this.waiting);
    const result = await this.call({ op: "poll" });
    for (const packet of result.packets) {
      const deviceId = this.deviceForLink.get(packet.link);
      if (deviceId) this.options.relay?.uplink.send(deviceId, fromBase64Url(packet.data));
    }
    this.relayUdpUp = result.relayUdp === true;
    if (Array.isArray(result.mapped)) {
      const mapped = result.mapped.filter((value) => value && typeof value.address === "string" && value.address.length <= 128 && Number.isInteger(value.port) && value.port > 0 && value.port <= 65535).slice(0, MAX_STUN_SERVERS);
      if (JSON.stringify(mapped) !== JSON.stringify(this.mapped)) {
        this.mapped = mapped;
        this.updateCandidates();
      }
    }
    const alive = new Set(result.connections.map((connection) => connection.id));
    for (const state of result.connections) {
      let channel = this.channels.get(state.id);
      const key3 = keyHex(state.remoteKey);
      if (state.dead || state.closedByPeer || !this.options.admit(key3)) {
        channel?.close({ drain: false });
        this.waiting.get(state.id)?.reject(new Error("NATIVE_CONNECTION_CLOSED"));
        this.waiting.delete(state.id);
        if (!channel) void this.call({ op: "close", id: state.id }).catch(() => void 0);
        continue;
      }
      try {
        if (!channel && state.established) {
          channel = new NativeChannel(this, state.id, key3);
          this.channels.set(state.id, channel);
          await channel.initialize();
          const waiting = this.waiting.get(state.id);
          if (waiting) {
            if (now() >= waiting.deadline) throw new Error("NATIVE_CONNECT_TIMEOUT");
            this.waiting.delete(state.id);
            waiting.resolve(channel);
          } else this.options.onIncoming(channel);
        }
        if (channel) {
          channel.receive(state);
          await channel.flush();
        }
      } catch (error) {
        channel?.close({ drain: false });
        this.waiting.get(state.id)?.reject(error instanceof Error ? error : new Error("NATIVE_CONNECTION_CLOSED"));
        this.waiting.delete(state.id);
        this.engine.assertCurrent?.();
      }
    }
    for (const [id, channel] of this.channels) if (!alive.has(id)) channel.close({ drain: false });
    for (const [id, waiting] of this.waiting) if (now() >= waiting.deadline || waitingAtPoll.get(id) === waiting && !alive.has(id)) {
      this.waiting.delete(id);
      waiting.reject(new Error("NATIVE_CONNECT_TIMEOUT"));
      void this.call({ op: "close", id }).catch(() => void 0);
    }
    if (this.waiting.size > 0 || [...this.channels.values()].some((channel) => channel.moving) || result.connections.some((state) => !state.established || state.unacked || state.data.length > 0 || state.events.length > 0 || state.buffered?.some(([, bytes]) => bytes > 0))) this.activeUntil = now() + ACTIVE_WINDOW_MS;
  }
  detach(id) {
    this.channels.delete(id);
    if (!this.closed) void this.call({ op: "close", id }).catch(() => void 0);
  }
  async close() {
    if (this.closed) return;
    this.closed = true;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    const ids = [...this.channels.keys(), ...this.waiting.keys()];
    for (const pending of this.waiting.values()) pending.reject(new Error("NATIVE_TRANSPORT_CLOSED"));
    this.waiting.clear();
    for (const channel of [...this.channels.values()]) channel.close({ drain: false });
    this.channels.clear();
    if (this.enhanced && ids.length) {
      try {
        this.engine.assertCurrent?.();
        for (const id of ids) await this.engine.command({ op: "close", id });
        await this.engine.command({ op: "poll" });
      } catch {
      }
    }
    await this.engine.destroy();
  }
};
var Outgoing = class {
  constructor(priority, reserved) {
    __publicField(this, "priority", priority);
    __publicField(this, "reserved", reserved);
    __publicField(this, "stream", null);
    __publicField(this, "items", []);
    __publicField(this, "queued", 0);
    /** Bytes in the core's send buffer for this stream at the last poll (0 on builds without `stream-buffered`). */
    __publicField(this, "core", 0);
  }
  push(bytes) {
    this.items.push({ bytes, offset: 0 });
    this.queued += bytes.length;
  }
};
var NativeChannel = class {
  constructor(owner, id, remoteId) {
    __publicField(this, "owner", owner);
    __publicField(this, "id", id);
    __publicField(this, "remoteId", remoteId);
    __publicField(this, "events", new ChannelEvents());
    __publicField(this, "data", new Outgoing("normal", true));
    __publicField(this, "control", new Outgoing("interactive", false));
    /** Session lanes, opened on first use after the peer declared session support (as the Desktop's CoreChannel). */
    __publicField(this, "lanes", null);
    __publicField(this, "streams", /* @__PURE__ */ new Map());
    __publicField(this, "state", null);
    __publicField(this, "candidates", []);
    __publicField(this, "candidateCursor", 0);
    __publicField(this, "nextProbe", 0);
    __publicField(this, "disposed", false);
    __publicField(this, "closeDeadline", 0);
    __publicField(this, "finished", false);
    __publicField(this, "sessionCapable", false);
    __publicField(this, "sessionsDeclared", false);
    __publicField(this, "peerSessionFeatures", []);
    __publicField(this, "sessionCapableHandlers", []);
    __publicField(this, "sessionHandler", null);
    __publicField(this, "earlySession", []);
    __publicField(this, "earlySessionBytes", 0);
    __publicField(this, "drainHandlers", []);
  }
  async initialize() {
    this.data.stream = await this.owner.call({ op: "openStream", id: this.id });
    await this.owner.call({ op: "write", id: this.id, stream: this.data.stream, data: toBase64Url(Uint8Array.of(DATA)) });
    this.control.stream = await this.owner.call({ op: "openStream", id: this.id, priority: "interactive" });
    const bytes = concatBytes([Uint8Array.of(CONTROL), utf8(JSON.stringify({ candidates: this.owner.candidates() }) + "\n")]);
    await this.owner.call({ op: "write", id: this.id, stream: this.control.stream, data: toBase64Url(bytes) });
  }
  /** This side's candidates changed (STUN answered, another network): tell the peer, as the Desktop re-announces. */
  announceCandidates() {
    if (this.events.closed || !this.owner.candidates().length) return;
    this.control.push(utf8(JSON.stringify({ candidates: this.owner.candidates() }) + "\n"));
    this.owner.wake();
  }
  send(bytes) {
    if (this.events.closed) throw new Error("NATIVE_CONNECTION_CLOSED");
    this.owner.reserve(bytes.length);
    this.data.push(bytes.slice());
    this.owner.wake();
  }
  get bufferedAmount() {
    return this.data.queued + this.control.queued;
  }
  /** Bytes still waiting here for the engine, or a close still draining: the transport keeps polling fast. */
  get moving() {
    return !this.disposed && (this.closeDeadline > 0 || this.data.queued > 0 || this.control.queued > 0 || this.lanes !== null && (this.lanes.control.queued > 0 || this.lanes.normal.queued > 0 || this.lanes.background.queued > 0));
  }
  onDrain(handler) {
    this.drainHandlers.push(handler);
  }
  /** See CoreChannel.declareSessions (transport.ts): once per connection, on the control stream older nodes read only for candidates. */
  declareSessions(features = []) {
    if (!this.owner.enhanced || this.sessionsDeclared || this.events.closed) return;
    this.sessionsDeclared = true;
    this.control.push(utf8(`${JSON.stringify({ session: [AGENT_NET_SESSION_V1, ...features] })}
`));
    this.owner.wake();
  }
  sessionFeatures() {
    return this.peerSessionFeatures;
  }
  onSessionCapable(handler) {
    if (this.sessionCapable) handler();
    else this.sessionCapableHandlers.push(handler);
  }
  sessionWire() {
    if (!this.sessionCapable || this.events.closed) return null;
    if (!this.lanes) {
      const open = (lane) => {
        const outgoing = new Outgoing(SESSION_LANE_PRIORITY[lane], false);
        outgoing.push(Uint8Array.of(SESSION_LANE_KINDS[lane]));
        return outgoing;
      };
      this.lanes = { control: open("control"), normal: open("normal"), background: open("background") };
    }
    const lanes = this.lanes;
    return {
      write: (lane, bytes) => {
        if (!this.events.closed) {
          lanes[lane].push(bytes);
          this.owner.wake();
        }
      },
      // As the Desktop (transport.ts): control and normal lanes count what the core still buffers, so a slow line pushes
      // back before a megabyte of pushes queues ahead of interactive replies; the background lane (file blocks) counts
      // only what waits here, so a download does not hold back task text.
      get bufferedAmount() {
        return lanes.control.queued + lanes.control.core + lanes.normal.queued + lanes.normal.core + lanes.background.queued;
      },
      onData: (handler) => {
        this.sessionHandler = handler;
        for (const [lane, bytes] of this.earlySession.splice(0)) handler(lane, bytes);
        this.earlySessionBytes = 0;
      }
    };
  }
  sessionData(lane, bytes) {
    if (this.sessionHandler) {
      this.sessionHandler(lane, bytes);
      return;
    }
    this.earlySessionBytes += bytes.length;
    if (this.earlySessionBytes > MAX_EARLY_SESSION_BYTES) {
      this.close({ drain: false });
      return;
    }
    this.earlySession.push([lane, bytes.slice()]);
  }
  /** Hands queued bytes to the engine: control first, then the interactive lane, normal traffic, and the background lane last. */
  async flush() {
    if (this.disposed) return;
    if (this.closeDeadline && now() >= this.closeDeadline) {
      this.dispose();
      return;
    }
    const before = this.bufferedAmount;
    const order = this.owner.enhanced ? [this.control, ...this.lanes ? [this.lanes.control, this.lanes.normal] : [], this.data, ...this.lanes ? [this.lanes.background] : []] : [this.data];
    for (const outgoing of order) {
      if (this.disposed) return;
      await this.flushStream(outgoing);
    }
    if (this.owner.enhanced && before > DRAIN_LOW_WATER_BYTES && this.bufferedAmount <= DRAIN_LOW_WATER_BYTES) for (const handler of this.drainHandlers) handler();
    if (this.closeDeadline && !this.finished && order.every((outgoing) => !outgoing.items.length)) {
      this.finished = true;
      for (const outgoing of order) if (outgoing.stream !== null) await this.owner.call({ op: "finish", id: this.id, stream: outgoing.stream });
    }
  }
  async flushStream(outgoing) {
    if (!outgoing.items.length) return;
    if (outgoing.stream === null) outgoing.stream = await this.owner.call({ op: "openStream", id: this.id, priority: outgoing.priority });
    for (let turn = 0; turn < WRITES_PER_STREAM && outgoing.items.length && !this.disposed; turn++) {
      const item = outgoing.items[0], part = item.bytes.subarray(item.offset, item.offset + WRITE_CHUNK);
      const written = await this.owner.call({ op: "write", id: this.id, stream: outgoing.stream, data: toBase64Url(part) });
      if (!Number.isInteger(written) || written < 0 || written > part.length) throw new Error("INVALID_NATIVE_WRITE");
      if (!written) break;
      item.offset += written;
      outgoing.queued -= written;
      if (outgoing.reserved) this.owner.release(written);
      if (item.offset === item.bytes.length) outgoing.items.shift();
    }
  }
  receive(state) {
    this.state = state;
    if (Array.isArray(state.buffered)) {
      const core = new Map(state.buffered);
      for (const outgoing of [this.data, this.control, ...this.lanes ? Object.values(this.lanes) : []]) {
        outgoing.core = outgoing.stream === null ? 0 : core.get(outgoing.stream) ?? 0;
      }
    }
    if (this.disposed) return;
    if (this.closeDeadline && now() >= this.closeDeadline) {
      this.dispose();
      return;
    }
    for (const event of state.events) if (event.kind === "open") {
      if (this.streams.size >= 128) {
        this.close({ drain: false });
        return;
      }
      this.streams.set(event.stream, { kind: null, text: "" });
    }
    for (const chunk of state.data) {
      const stream = this.streams.get(chunk.stream);
      if (!stream) {
        this.close({ drain: false });
        return;
      }
      let data = fromBase64Url(chunk.data);
      if (stream.kind === null && data.length) {
        stream.kind = data[0];
        data = data.subarray(1);
      }
      if (stream.kind === DATA) {
        if (data.length) this.events.data(data);
        continue;
      }
      const lane = !this.owner.enhanced || stream.kind === null ? void 0 : LANE_BY_KIND.get(stream.kind);
      if (lane) {
        if (data.length) this.sessionData(lane, data);
        if (this.disposed) return;
        continue;
      }
      if (stream.kind === CONTROL) {
        stream.text += decodeUtf8(data);
        if (stream.text.length > 8192) {
          this.close({ drain: false });
          return;
        }
        for (let end = stream.text.indexOf("\n"); end >= 0; end = stream.text.indexOf("\n")) {
          this.onControl(stream.text.slice(0, end));
          stream.text = stream.text.slice(end + 1);
        }
      } else if (stream.kind !== null) {
        this.close({ drain: false });
        return;
      }
    }
    for (const event of state.events) if (event.kind === "finish") {
      if (this.streams.get(event.stream)?.kind === DATA) {
        this.close();
        return;
      }
      this.streams.delete(event.stream);
    }
    if (!this.events.closed && now() >= this.nextProbe && this.candidates.length) {
      this.nextProbe = now() + 1e4;
      const count = Math.min(4, this.candidates.length);
      for (let index = 0; index < count; index++) {
        const address = this.candidates[(this.candidateCursor + index) % this.candidates.length];
        void this.owner.call({ op: "probe", id: this.id, address }).catch(() => void 0);
      }
      this.candidateCursor = (this.candidateCursor + count) % this.candidates.length;
    }
  }
  onControl(line) {
    let value;
    try {
      value = JSON.parse(line);
    } catch {
      return;
    }
    if (this.owner.enhanced && Array.isArray(value?.session) && value.session.includes(AGENT_NET_SESSION_V1) && !this.sessionCapable) {
      this.sessionCapable = true;
      this.peerSessionFeatures = value.session.filter((feature) => typeof feature === "string" && feature !== AGENT_NET_SESSION_V1 && feature.length <= 64).slice(0, 16);
      for (const handler of this.sessionCapableHandlers.splice(0)) handler();
    }
    if (Array.isArray(value?.candidates)) {
      const candidates = value.candidates.filter((a) => a && typeof a.address === "string" && a.address.length <= 128 && Number.isInteger(a.port) && a.port > 0 && a.port <= 65535);
      if (this.owner.enhanced) candidates.sort((a, b) => Number(isPrivate(a.address)) - Number(isPrivate(b.address)));
      this.candidates = candidates.slice(0, MAX_CANDIDATES);
      this.candidateCursor = 0;
      this.nextProbe = 0;
    }
  }
  onData(handler) {
    this.events.onData(handler);
  }
  onClose(handler) {
    this.events.onClose(handler);
  }
  path() {
    return this.events.closed || !this.state?.path ? null : "link" in this.state.path ? "relay" : "direct";
  }
  stats() {
    return this.events.closed || !this.state ? null : { srttUs: this.state.rttUs, sent: this.state.sent, received: this.state.received, rotations: this.state.rotations };
  }
  close(options) {
    if (this.disposed) return;
    this.events.close();
    if (options?.drain !== false) {
      this.closeDeadline || (this.closeDeadline = now() + 2e3);
      this.owner.wake();
      return;
    }
    this.dispose();
  }
  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    for (const item of this.data.items) this.owner.release(item.bytes.length - item.offset);
    for (const outgoing of [this.data, this.control, ...this.lanes ? Object.values(this.lanes) : []]) {
      outgoing.items = [];
      outgoing.queued = 0;
    }
    this.streams.clear();
    this.earlySession = [];
    this.events.close();
    this.owner.detach(this.id);
  }
};
function isPrivate(address) {
  if (address.includes(":")) return /^(fe80:|fc|fd)/i.test(address);
  const [a, b] = address.split(".").map(Number);
  return a === 10 || a === 127 || a === 172 && b >= 16 && b < 32 || a === 192 && b === 168 || a === 100 && b >= 64 && b < 128 || a === 169 && b === 254;
}

// native/portable/host.ts
async function connect(configText, host) {
  if (typeof globalThis.URL !== "function") globalThis.URL = class {
    constructor(value) {
      Object.assign(this, JSON.parse(host.parseUrl(value)));
    }
  };
  const config = JSON.parse(configText);
  const assertCurrent = () => host.check();
  let closed = false;
  const guard = () => {
    if (closed) throw new Error("AGENT_NET_CLOSED");
    assertCurrent();
  };
  const command = (input) => {
    guard();
    const reply = JSON.parse(host.command(JSON.stringify(input)));
    if (!reply.ok) throw new Error(reply.code || "AGENT_NET_ENGINE_FAILED");
    return reply.value;
  };
  const engine = {
    command: async (input) => command(input),
    assertCurrent: guard,
    destroy: async () => host.destroy()
  };
  const identity = command({ op: "identity" });
  const verifyCertificate = (root, certificate, now2 = Date.now()) => certificatePolicyValid(certificate, now2) && command({ op: "verify", key: root, text: certificatePayload(certificate), signature: certificate.signature }) === true;
  const sockets = /* @__PURE__ */ new Set();
  const createWebSocket = (url, headers) => {
    const ws = {
      readyState: 0,
      bufferedAmount: 0,
      binaryType: "arraybuffer",
      onmessage: null,
      onerror: null,
      onclose: null,
      send(data) {
        guard();
        wire.send(typeof data === "string" ? data : toBase64Url(data), typeof data !== "string");
      },
      close() {
        sockets.delete(wire);
        wire.close();
      }
    };
    const wire = host.socket(url, JSON.stringify(headers), {
      open() {
        ws.readyState = 1;
      },
      message(data, binary) {
        if (!closed) ws.onmessage?.({ data: binary ? fromBase64Url(data).buffer : data });
      },
      error() {
        ws.onerror?.({ message: "AGENT_NET_NETWORK_ERROR" });
      },
      close(code) {
        ws.readyState = 3;
        ws.onclose?.({ code });
      }
    });
    sockets.add(wire);
    return ws;
  };
  const fetch2 = async (url, init = {}) => {
    guard();
    if (init.signal?.aborted) throw new Error("AGENT_NET_CANCELLED");
    const binary = init.body instanceof Uint8Array;
    const result = JSON.parse(await host.binaryRequest(
      url,
      init.method || "GET",
      JSON.stringify(init.headers || {}),
      binary ? toBase64Url(init.body) : init.body || "",
      binary
    ));
    guard();
    const bytes = fromBase64Url(result.body);
    return {
      ok: result.status >= 200 && result.status < 300,
      status: result.status,
      headers: { get(name) {
        const key3 = Object.keys(result.headers || {}).find((k) => k.toLowerCase() === name.toLowerCase());
        return key3 ? result.headers[key3] : null;
      } },
      json: async () => JSON.parse(new TextDecoder().decode(bytes)),
      arrayBuffer: async () => bytes.buffer
    };
  };
  const client = new PortableAgentNetClient(config.baseUrl, {
    identity,
    sign: async (text2) => command({ op: "sign", text: text2 }),
    random: async () => command({ op: "random" })
  }, config.certificate, config.rootPublicKey, {
    assertCurrent: guard,
    sha256: (bytes) => host.sha256(toBase64Url(bytes)),
    verifyCertificate,
    createWebSocket,
    fetch: fetch2,
    ownerPinnedHttp: true,
    relayUdpEnabled: () => false
  });
  let transport;
  let socket;
  try {
    socket = await AgentNetSocket.openWithBindings({
      client,
      userId: config.accountId,
      assertCurrent: guard,
      lanDiscovery: false,
      bindings: {
        verifyCertificate,
        createTransport: async (options) => {
          transport = await NativeTransport.create(engine, options, [], false);
          return transport;
        }
      }
    });
    socket.on("message", (event) => host.message(typeof event === "string" ? event : event.toString()));
    socket.on("close", (code) => host.close(code || 1006));
    socket.on("error", () => host.error());
    return {
      send(text2) {
        guard();
        socket.send(text2);
      },
      async upload(deviceId, encoded, contentType) {
        guard();
        const bytes = fromBase64Url(encoded);
        if (bytes.length > 30 * 1024 * 1024) throw new Error("ATTACHMENT_TOO_LARGE");
        const directory = await client.directory();
        guard();
        const recipient = directory.find((item) => item.certificate.deviceId === deviceId);
        if (!recipient) throw new Error("AGENT_NET_MEDIA_PEER_UNAVAILABLE");
        const result = await uploadNativeMedia(
          client,
          engine,
          deviceId,
          recipient.certificate.transportKey,
          bytes.length,
          async (offset, length) => bytes.slice(offset, offset + length),
          { assertCurrent: guard, binding: agentNetMediaBinding(config.relayId) }
        );
        return buildAgentNetMediaKey({ slot: config.relayId, networkId: config.certificate.networkId, id: result.id, headerSha256: result.headerSha256, contentType });
      },
      async download(key3) {
        guard();
        const ref = parseAgentNetMediaKey(key3);
        if (!ref || ref.slot !== config.relayId || ref.networkId !== config.certificate.networkId || ref.grantId || ref.sharedTask)
          throw new Error("AGENT_NET_MEDIA_SCOPE_MISMATCH");
        const reader = await openNativeMediaReader(client, engine, ref.id, ref.headerSha256, { assertCurrent: guard, binding: agentNetMediaBinding(ref.slot) });
        try {
          if (reader.size > 30 * 1024 * 1024) throw new Error("ATTACHMENT_TOO_LARGE");
          const output = new Uint8Array(reader.size);
          await reader.read(0, reader.size - 1, async (bytes, offset) => {
            output.set(bytes, offset);
          });
          guard();
          return "data:" + ref.contentType + ";base64," + toBase64Url(output).replace(/-/g, "+").replace(/_/g, "/");
        } finally {
          await reader.close();
        }
      },
      async deleteMedia(key3) {
        const ref = parseAgentNetMediaKey(key3);
        if (!ref || ref.slot !== config.relayId || ref.networkId !== config.certificate.networkId) throw new Error("AGENT_NET_MEDIA_SCOPE_MISMATCH");
        await client.request("DELETE", "/media/" + encodeURIComponent(ref.id));
      },
      close() {
        if (closed) return;
        socket.close();
        sockets.forEach((wire) => wire.close());
        sockets.clear();
        host.destroy();
        closed = true;
      },
      async request(method, resource, body) {
        guard();
        return JSON.stringify(await client.request(method, resource, body ? JSON.parse(body) : void 0));
      },
      async directory() {
        guard();
        const devices = await client.directory();
        return JSON.stringify(devices);
      }
    };
  } catch (error) {
    socket?.close();
    sockets.forEach((wire) => wire.close());
    sockets.clear();
    await engine.destroy();
    closed = true;
    throw error;
  }
}
function accountOffers(value) {
  return JSON.stringify(parseRelayAccountOffers(JSON.parse(value)));
}
function accountBoard(value, now2) {
  return JSON.stringify(parseRelayAccountJoinBoard(JSON.parse(value), now2));
}
function editAccountBoard(value, now2, deviceId, requestId, request) {
  const board = parseRelayAccountJoinBoard(JSON.parse(value), now2);
  if (request) {
    board.requests[deviceId] = JSON.parse(request);
    delete board.invites[deviceId];
  } else {
    if (board.requests[deviceId]?.requestId === requestId) delete board.requests[deviceId];
    if (board.invites[deviceId]?.requestId === requestId) delete board.invites[deviceId];
  }
  return JSON.stringify(serializeRelayAccountJoinBoard(board));
}
function installUrlParser(parse, query) {
  if (typeof globalThis.URLSearchParams !== "function") globalThis.URLSearchParams = class {
    constructor(value) {
      this.values = JSON.parse(query(String(value)));
    }
    get(key3) {
      return Object.prototype.hasOwnProperty.call(this.values, key3) ? this.values[key3] : null;
    }
  };
  if (typeof globalThis.URL !== "function") globalThis.URL = class {
    constructor(value) {
      Object.assign(this, JSON.parse(parse(value)));
    }
  };
}
export {
  accountBoard,
  accountOffers,
  connect,
  editAccountBoard,
  installUrlParser,
  parseRelayAccountJoinBoard,
  parseRelayAccountOffers,
  serializeRelayAccountJoinBoard
};
