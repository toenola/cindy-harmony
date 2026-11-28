// Generated from fixed upstream 91179cedad; source: core/shared-tasks/portable/SharingBridge.mjs
var __defProp = Object.defineProperty;
var __defNormalProp = (obj, key3, value) => key3 in obj ? __defProp(obj, key3, { enumerable: true, configurable: true, writable: true, value }) : obj[key3] = value;
var __publicField = (obj, key3, value) => __defNormalProp(obj, typeof key3 !== "symbol" ? key3 + "" : key3, value);

// .cache/shared-task-portable-91179cedad/packages/agent-net-protocol/src/sharingOrigins.ts
function stripTrailingSlashes(value) {
  let end = value.length;
  while (end > 0 && value.charCodeAt(end - 1) === 47) end--;
  return value.slice(0, end);
}
function agentNetSharingSubject(accountId, accountRegion, networkRegion) {
  return accountRegion === networkRegion ? accountId : "x:" + accountRegion + ":" + accountId;
}

// .cache/shared-task-portable-91179cedad/packages/agent-net-protocol/src/index.ts
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
  const time = (v) => Number.isSafeInteger(v) && Number(v) >= 0;
  return Object.keys(c).length === 11 && c.v === 2 && id(c.networkId) && id(c.subject) && id(c.deviceId) && id(c.serial) && key3(c.signingKey) && key3(c.transportKey) && ["owner", "member"].includes(c.role) && time(c.issuedAt) && time(c.expiresAt) && c.issuedAt <= now2 + 3e4 && c.expiresAt > now2 && c.expiresAt > c.issuedAt && (c.networkId.startsWith("private:") || c.expiresAt - c.issuedAt <= CERT_LIFETIME_MS) && typeof c.signature === "string";
}
function delegationPayload(d) {
  return JSON.stringify([
    "cindy-agent-net/delegation/2",
    d.v,
    d.id,
    d.kind,
    d.networkId,
    d.hostDeviceId,
    d.resourceId,
    d.guestDeviceId,
    d.guestSigningKey,
    d.guestTransportKey,
    d.issuedAt,
    d.expiresAt,
    d.issuerCertificate,
    ...d.scope === void 0 ? [] : [[d.scope.memberId, d.scope.guestSubject, d.scope.memberVersion]],
    ...d.executors === void 0 ? [] : [d.executors.map((e) => [e.generation, e.certificate, e.expiresAt])]
  ]);
}
function sharingIdentityPayload(networkId, rootPublicKey, deviceId, signingKey) {
  return JSON.stringify(["cindy-agent-net/sharing-identity/2", networkId, rootPublicKey, deviceId, signingKey]);
}
function guestRequestPath(path, networkId, delegationId) {
  return JSON.stringify(["cindy-agent-net/guest-request/2", path, networkId, delegationId]);
}
function delegationPolicyValid(value, now2 = Date.now()) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const d = value;
  const id = (v) => typeof v === "string" && ID_PATTERN.test(v);
  const key3 = (v) => typeof v === "string" && KEY_PATTERN.test(v) && /[AEIMQUYcgkosw048]$/.test(v);
  return d.v === 2 && id(d.id) && (d.kind === "provider-share" || d.kind === "shared-task") && id(d.resourceId) && id(d.guestDeviceId) && key3(d.guestSigningKey) && key3(d.guestTransportKey) && (d.scope === void 0 || delegationScopeValid(d.scope)) && (d.executors === void 0 || d.kind === "provider-share" && !!d.scope && Array.isArray(d.executors) && d.executors.length <= 32 && new Set(d.executors.map((e) => e?.certificate?.deviceId)).size === d.executors.length && d.executors.every((e) => e && id(e.generation) && certificatePolicyValid(e.certificate, d.issuedAt) && e.certificate.networkId === d.networkId && e.certificate.subject === d.issuerCertificate?.subject && e.certificate.deviceId !== d.hostDeviceId && Number.isSafeInteger(e.expiresAt) && e.expiresAt > d.issuedAt && e.expiresAt <= d.expiresAt && e.expiresAt <= e.certificate.expiresAt)) && Number.isSafeInteger(d.issuedAt) && d.issuedAt >= 0 && Number.isSafeInteger(d.expiresAt) && d.issuedAt <= now2 + 3e4 && d.expiresAt > now2 && d.expiresAt > d.issuedAt && d.expiresAt - d.issuedAt <= MAX_GRANT_LIFETIME_MS && certificatePolicyValid(d.issuerCertificate, now2) && d.issuerCertificate.networkId === d.networkId && d.issuerCertificate.deviceId === d.hostDeviceId && typeof d.signature === "string";
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

// .cache/shared-task-portable-91179cedad/packages/device-link-protocol/src/sharedTask.ts
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

// .cache/shared-task-portable-91179cedad/packages/device-link-protocol/src/providerShare.ts
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

// .cache/shared-task-portable-91179cedad/packages/device-link-protocol/src/protocol.ts
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

// .cache/shared-task-portable-91179cedad/packages/device-link/src/sharedTaskPeer.ts
function key(peer) {
  return JSON.stringify([peer.sharedTaskId, peer.role, peer.role === "guest" ? peer.memberId : null, peer.deviceId]).padEnd(129, "~");
}
function sharedTaskHostPeer(sharedTaskId, deviceId) {
  return key({ sharedTaskId: sharedTaskIdentifier(sharedTaskId), role: "host", deviceId: sharedTaskDeviceId(deviceId) });
}
function sharedTaskGuestPeer(sharedTaskId, memberId, deviceId) {
  return key({ sharedTaskId: sharedTaskIdentifier(sharedTaskId), role: "guest", memberId: sharedTaskIdentifier(memberId), deviceId: sharedTaskDeviceId(deviceId) });
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
    return key(peer) === value ? peer : null;
  } catch {
    return null;
  }
}

// .cache/shared-task-portable-91179cedad/packages/device-link/src/providerSharePeer.ts
var TAG = "provider-share";
function key2(peer) {
  return JSON.stringify([TAG, peer.shareId, peer.role, peer.role === "guest" ? peer.memberId : null, peer.deviceId]).padEnd(129, "~");
}
function providerShareHostPeer(shareId, deviceId) {
  return key2({ shareId: providerShareIdentifier(shareId), role: "host", deviceId: sharedTaskDeviceId(deviceId) });
}
function providerShareGuestPeer(shareId, memberId, deviceId) {
  return key2({ shareId: providerShareIdentifier(shareId), role: "guest", memberId: providerShareIdentifier(memberId), deviceId: sharedTaskDeviceId(deviceId) });
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
    return key2(peer) === value ? peer : null;
  } catch {
    return null;
  }
}

// .cache/shared-task-portable-91179cedad/packages/device-link/src/selfHostedRelayAuth.ts
var RELAY_FRAME_MAX_SKEW_MS = 10 * 60 * 1e3;
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
function utf8Bytes(text) {
  const out = [];
  for (let i = 0; i < text.length; i++) {
    let code = text.charCodeAt(i);
    if (code >= 55296 && code <= 56319 && i + 1 < text.length) {
      const next = text.charCodeAt(i + 1);
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

// .cache/shared-task-portable-91179cedad/peers.ts
function computeDuplicateIdentityCooldownMs(input) {
  const streak = Number.isFinite(input.streak) ? Math.max(0, Math.floor(input.streak)) : 0;
  if (streak === 0) return 0;
  return Math.min(input.baseMs * 2 ** (streak - 1), input.maxMs);
}

// .cache/shared-task-portable-91179cedad/packages/agent-net/src/portableBytes.ts
function fromBase64Url(text) {
  const result = decodeBase64Url(text);
  if (result === null) throw new Error("INVALID_BASE64URL");
  return result;
}
var toBase64Url = encodeBase64Url;
var utf8 = (text) => typeof TextEncoder === "function" ? new TextEncoder().encode(text) : utf8Bytes(text);
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
var keyHex = (text) => Array.from(fromBase64Url(text), (byte) => byte.toString(16).padStart(2, "0")).join("");
function concatBytes(parts) {
  const result = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

// .cache/shared-task-portable-91179cedad/packages/agent-net/src/sharingClient.ts
var AgentNetSharingError = class extends Error {
  constructor(status, code, retryAt) {
    super(code);
    __publicField(this, "status", status);
    __publicField(this, "code", code);
    __publicField(this, "retryAt", retryAt);
  }
};
function cardLifetimeMs(card) {
  const parts = card.split(".");
  if (parts.length !== 3) return;
  let claims;
  try {
    claims = JSON.parse(decodeUtf8(fromBase64Url(parts[1])));
  } catch {
    return;
  }
  const { iat, exp } = claims ?? {};
  if (typeof iat !== "number" || typeof exp !== "number" || !Number.isFinite(iat) || !Number.isFinite(exp) || exp <= iat || exp - iat > 300) return;
  return (exp - iat) * 1e3;
}
function retryDeadline(headers) {
  const value = headers.get("retry-after")?.trim();
  if (!value) return;
  const now2 = Date.now();
  const serverTime = Date.parse(headers.get("date") ?? "");
  const delay = /^\d+$/.test(value) ? Number(value) * 1e3 : Date.parse(value) - (Number.isFinite(serverTime) ? serverTime : now2);
  if (Number.isFinite(delay) && delay >= 0) return now2 + delay;
}
var AgentNetSharingClient = class {
  constructor(options) {
    __publicField(this, "options", options);
    __publicField(this, "base");
    __publicField(this, "closed", false);
    __publicField(this, "cached", null);
    __publicField(this, "cardRequest", null);
    __publicField(this, "requests", /* @__PURE__ */ new Set());
    __publicField(this, "receipts", /* @__PURE__ */ new Set());
    const url = new URL(options.base);
    if (url.username || url.password || url.search || url.hash || url.protocol !== "https:" && !(url.protocol === "http:" && (options.ownerPinnedHttp || ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname)))) throw new Error("SECURE_AGENT_NET_URL_REQUIRED");
    this.base = stripTrailingSlashes(options.base);
  }
  current(check2) {
    if (this.closed || check2?.() === false) throw new Error("AGENT_NET_OWNER_CHANGED");
    this.options.assertCurrent();
  }
  card() {
    this.current();
    if (this.cached && this.cached.expiresAt - Date.now() > 3e4) return Promise.resolve(this.cached.card);
    if (this.cardRequest) return this.cardRequest;
    const { networkId, rootPublicKey, signer } = this.options;
    const bytes = this.options.hash(utf8(sharingIdentityPayload(networkId, rootPublicKey, signer.identity.deviceId, signer.identity.signingKey)));
    const nonce = Array.from(bytes, (n) => n.toString(16).padStart(2, "0")).join("");
    const requestedAt = Date.now();
    this.cardRequest = this.options.getIdentityCard(nonce).then((value) => {
      this.current();
      const lifetime = typeof value.card === "string" && value.card.length <= 8192 ? cardLifetimeMs(value.card) : void 0;
      if (lifetime === void 0) throw new Error("INVALID_AGENT_NET_IDENTITY_CARD");
      this.cached = { card: value.card, expiresAt: requestedAt + lifetime };
      return value.card;
    }).finally(() => {
      this.cardRequest = null;
    });
    return this.cardRequest;
  }
  async request(resource, options) {
    this.current(options.isCurrent);
    const resourcePath = /^\/api\/device-link\/(shared-tasks|provider-shares)(\/|$)/.test(resource) ? resource.replace("/api/device-link/", "/api/agent-net/sharing/") : /^\/api\/agent-net\/sharing\/transport(?:\/status)?$/.test(resource) ? resource : "";
    const path = this.options.privateSharing ? resourcePath.replace("/api/agent-net/sharing/", "/api/agent-net/private-sharing/") : resourcePath;
    if (!path || path.includes("?") || path.includes("#") || new URL(this.base + path).pathname !== path || !["GET", "POST"].includes(options.method)) throw new Error("INVALID_AGENT_NET_SHARING_RESOURCE");
    const body = options.body === void 0 ? "" : JSON.stringify(options.body);
    if (utf8(body).length > 16384) throw new Error("SHARING_REQUEST_TOO_LARGE");
    const card = this.options.privateSharing ? void 0 : await this.card();
    this.current(options.isCurrent);
    const { signer } = this.options;
    const entropy = await signer.random();
    this.current(options.isCurrent);
    const proof = { at: Date.now(), nonce: entropy.slice(0, 24) };
    if (!/^[A-Za-z0-9_-]{24}$/.test(proof.nonce)) throw new Error("INVALID_NATIVE_RANDOM");
    const signature = await signer.sign(requestPayload(options.method, this.options.privateSharing ? JSON.stringify(["private-sharing/1", this.options.networkId, this.options.rootPublicKey, path]) : path, toBase64Url(this.options.hash(utf8(body))), proof));
    this.current(options.isCurrent);
    const authorization = (this.options.privateSharing ? "AgentNetPrivate " : "AgentNetIdentity ") + toBase64Url(utf8(JSON.stringify({
      networkId: this.options.networkId,
      ...this.options.privateSharing ? {} : { deviceId: signer.identity.deviceId, card },
      signingKey: signer.identity.signingKey,
      proof: { ...proof, signature }
    })));
    const member = await this.options.memberAuthorization?.(options.method, path, body);
    this.current(options.isCurrent);
    let applicant;
    if (options.applicant) {
      const signer2 = options.applicant;
      if (signer2.identity.deviceId !== (this.options.privateSharing ? "guest:" + this.options.signer.identity.signingKey : this.options.signer.identity.deviceId)) throw new Error("APPLICANT_DEVICE_MISMATCH");
      const entropy2 = await signer2.random();
      this.current(options.isCurrent);
      const proof2 = { at: Date.now(), nonce: entropy2.slice(0, 24) };
      if (!/^[A-Za-z0-9_-]{24}$/.test(proof2.nonce)) throw new Error("INVALID_NATIVE_RANDOM");
      const signature2 = await signer2.sign(requestPayload(options.method, path, toBase64Url(this.options.hash(utf8(body))), proof2));
      this.current(options.isCurrent);
      applicant = toBase64Url(utf8(JSON.stringify({ ...proof2, signature: signature2 })));
    }
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 15e3);
    const abort = () => controller.abort();
    if (options.signal?.aborted) controller.abort();
    else options.signal?.addEventListener("abort", abort, { once: true });
    this.requests.add(controller);
    if (options.observeResponse) this.receipts.add(controller);
    try {
      const response = await (this.options.fetch ?? fetch)(this.base + path, {
        method: options.method,
        headers: {
          authorization,
          ...member ? { "x-agent-net-authorization": member } : {},
          ...applicant ? { "x-agent-net-applicant": applicant } : {},
          ...body ? { "content-type": "application/json" } : {}
        },
        ...body ? { body } : {},
        redirect: "error",
        signal: controller.signal
      });
      if (!options.observeResponse) this.current(options.isCurrent);
      const length = response.headers.get("content-length");
      if (length && /^\d+$/.test(length) && Number(length) > MAX_CONTROL_BYTES) throw new Error("SHARING_RESPONSE_TOO_LARGE");
      let text;
      if (response.body?.getReader) {
        const reader = response.body.getReader(), parts = [];
        let size = 0;
        try {
          for (; ; ) {
            const next = await reader.read();
            if (!options.observeResponse) this.current(options.isCurrent);
            if (next.done) break;
            size += next.value.length;
            if (size > MAX_CONTROL_BYTES) {
              await reader.cancel();
              throw new Error("SHARING_RESPONSE_TOO_LARGE");
            }
            parts.push(next.value);
          }
          text = decodeUtf8(concatBytes(parts));
        } finally {
          reader.releaseLock();
        }
      } else text = await response.text();
      if (utf8(text).length > MAX_CONTROL_BYTES) throw new Error("SHARING_RESPONSE_TOO_LARGE");
      let value;
      try {
        value = JSON.parse(text);
      } catch {
        if (response.status !== 429) throw new Error("INVALID_SHARING_RESPONSE");
      }
      if (!response.ok) {
        this.current(options.isCurrent);
        if (response.status === 401) this.cached = null;
        throw new AgentNetSharingError(response.status, typeof value?.error?.code === "string" && /^[A-Z0-9_]{1,80}$/.test(value.error.code) ? value.error.code : "AGENT_NET_SHARING_FAILED", response.status === 429 ? retryDeadline(response.headers) : void 0);
      }
      options.observeResponse?.(value);
      this.current(options.isCurrent);
      return value;
    } finally {
      clearTimeout(timer);
      controller.abort();
      options.signal?.removeEventListener("abort", abort);
      this.requests.delete(controller);
      this.receipts.delete(controller);
    }
  }
  close() {
    this.closed = true;
    this.cached = null;
    for (const request of this.requests) if (!this.receipts.has(request)) request.abort();
  }
};

// .cache/shared-task-portable-91179cedad/packages/agent-net/src/sharingTransport.ts
var AgentNetSharingTransport = class {
  constructor(options) {
    __publicField(this, "options", options);
    __publicField(this, "closed", false);
    __publicField(this, "pending", null);
    __publicField(this, "cached", null);
    __publicField(this, "controller", null);
    if (options.client.options.networkId !== options.scope.networkId || options.client.options.rootPublicKey !== options.scope.rootPublicKey)
      throw new Error("AGENT_NET_SHARING_SCOPE_MISMATCH");
  }
  current() {
    if (this.closed) throw new Error("AGENT_NET_SHARING_CLOSED");
    this.options.assertCurrent();
  }
  inspect(value) {
    this.current();
    const r = value;
    const { scope, applicant } = this.options;
    if (!r || typeof r.id !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(r.id) || !["pending", "ready"].includes(r.status) || r.rootPublicKey !== scope.rootPublicKey || r.networkId !== scope.networkId || !this.options.verifyCertificate(scope.rootPublicKey, r.certificate) || r.certificate.networkId !== scope.networkId || r.certificate.deviceId !== scope.hostDeviceId)
      throw new Error("UNTRUSTED_AGENT_NET_SHARING_TRANSPORT");
    if (r.status === "pending") {
      if (r.delegation !== void 0) throw new Error("UNTRUSTED_AGENT_NET_SHARING_TRANSPORT");
      return { id: r.id };
    }
    const d = r.delegation;
    if (!this.options.verifyDelegation(scope.rootPublicKey, d) || d.id !== r.id || d.kind !== scope.kind || d.networkId !== scope.networkId || d.resourceId !== scope.resourceId || d.hostDeviceId !== scope.hostDeviceId || d.issuerCertificate.signature !== r.certificate.signature || d.guestDeviceId !== applicant.identity.deviceId || d.guestSigningKey !== applicant.identity.signingKey || d.guestTransportKey !== applicant.identity.transportKey || d.scope?.memberId !== scope.memberId || d.scope.guestSubject !== scope.guestSubject) throw new Error("UNTRUSTED_AGENT_NET_SHARING_TRANSPORT");
    return d.expiresAt - Date.now() > 6e4 ? { id: r.id, delegation: d } : { id: r.id };
  }
  acquire() {
    this.current();
    if (this.cached && this.cached.expiresAt - Date.now() > 6e4) return Promise.resolve(this.cached);
    if (this.pending) return this.pending;
    const controller = new AbortController();
    this.controller = controller;
    const timer = setTimeout(() => controller.abort(), 15e3);
    this.pending = this.acquireNow(controller.signal).then((d) => {
      this.current();
      this.cached = d;
      return d;
    }).finally(() => {
      clearTimeout(timer);
      this.pending = null;
      if (this.controller === controller) this.controller = null;
    });
    return this.pending;
  }
  async acquireNow(signal) {
    const { client, applicant, scope } = this.options;
    const request = (path, body) => client.request(path, {
      method: "POST",
      body,
      applicant,
      signal,
      isCurrent: () => {
        this.current();
        return true;
      }
    });
    let response = this.inspect(await request("/api/agent-net/sharing/transport", {
      kind: scope.kind,
      resourceId: scope.resourceId,
      memberId: scope.memberId,
      signingKey: applicant.identity.signingKey,
      transportKey: applicant.identity.transportKey
    }));
    const id = response.id;
    for (const delay of [250, 500, 1e3, 2e3, 4e3]) {
      if (response.delegation) return response.delegation;
      await this.wait(delay, signal);
      this.current();
      response = this.inspect(await request("/api/agent-net/sharing/transport/status", {
        id,
        signingKey: applicant.identity.signingKey,
        transportKey: applicant.identity.transportKey
      }));
      if (response.id !== id) throw new Error("AGENT_NET_SHARING_REQUEST_CHANGED");
    }
    if (response.delegation) return response.delegation;
    throw new Error("AGENT_NET_SHARING_HOST_UNAVAILABLE");
  }
  wait(ms, signal) {
    return new Promise((resolve, reject) => {
      const abort = () => {
        clearTimeout(timer);
        reject(new Error("AGENT_NET_SHARING_ABORTED"));
      };
      const timer = setTimeout(() => {
        signal.removeEventListener("abort", abort);
        resolve();
      }, ms);
      if (signal.aborted) abort();
      else signal.addEventListener("abort", abort, { once: true });
    });
  }
  close() {
    this.closed = true;
    this.cached = null;
    this.controller?.abort();
  }
};

// .cache/shared-task-portable-91179cedad/packages/agent-net/src/sharingInvitation.ts
var prefix = "an2.";
function server(value) {
  try {
    const url = new URL(value);
    if (url.username || url.password || url.search || url.hash || url.protocol !== "https:" && !(url.protocol === "http:" && ["127.0.0.1", "localhost", "[::1]"].includes(url.hostname))) return null;
    return url.origin + url.pathname.replace(/\/+$/, "");
  } catch {
    return null;
  }
}
function valid(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const r = value;
  const id = (v) => typeof v === "string" && ID_PATTERN.test(v);
  return Object.keys(r).length === 8 && (r.v === 2 || r.v === 3 && typeof r.networkId === "string" && r.networkId.startsWith("private:")) && (r.kind === "shared-task" || r.kind === "provider-share") && typeof r.invitation === "string" && /^[A-Za-z0-9_-]{43}$/.test(r.invitation) && id(r.networkId) && id(r.resourceId) && id(r.hostDeviceId) && typeof r.rootPublicKey === "string" && KEY_PATTERN.test(r.rootPublicKey) && /[AEIMQUYcgkosw048]$/.test(r.rootPublicKey) && (r.region === "cn" || r.region === "global");
}
function encodeAgentNetSharingInvitation(receipt) {
  if (!valid(receipt)) throw new Error("INVALID_AGENT_NET_SHARING_INVITATION");
  return prefix + toBase64Url(utf8(JSON.stringify(receipt)));
}
function decodeAgentNetSharingInvitation(value) {
  if (!value.startsWith(prefix) || value.length > 4096) return null;
  try {
    const r = JSON.parse(decodeUtf8(fromBase64Url(value.slice(prefix.length))));
    return valid(r) ? r : null;
  } catch {
    return null;
  }
}
function buildAgentNetSharingInvitation(receipt, base, app = "cindy") {
  const target = server(base);
  if (!target || !["cindy", "cindycn", "cindydev"].includes(app)) throw new Error("SECURE_SHARING_INVITATION_REQUIRED");
  return target + "/api/agent-net/" + receipt.kind + "/join#" + encodeAgentNetSharingInvitation(receipt) + (app === "cindy" ? "" : "?app=" + app);
}
function parseAgentNetSharingInvitation(input, expectedKind) {
  if (input.length > 8192) return null;
  try {
    let url;
    const trimmed = input.trim();
    if (/^cindy(?:cn|dev)?:\/\//.test(trimmed)) url = new URL(trimmed);
    else {
      const links = trimmed.match(/https?:\/\/[^\s<>"'，。！？、（）「」“”‘’\[\])]+/g)?.filter((value) => {
        try {
          return /\/api\/agent-net\/(shared-task|provider-share)\/join$/.test(new URL(value.replace(/[.,;!?]+$/, "")).pathname);
        } catch {
          return false;
        }
      });
      if (links?.length !== 1) return null;
      url = new URL(links[0].replace(/[.,;!?]+$/, ""));
    }
    if (url.username || url.password) return null;
    let encoded, base, kind;
    if (["cindy:", "cindycn:", "cindydev:"].includes(url.protocol)) {
      if (url.hash || url.port || [...url.searchParams.keys()].some((key3) => key3 !== "invitation" && key3 !== "server") || url.searchParams.getAll("invitation").length !== 1 || url.searchParams.getAll("server").length !== 1) return null;
      if (url.host === "shared-task" && url.pathname === "/join" || url.host === "shared-session" && !url.pathname) kind = "shared-task";
      else if (url.host === "provider-share" && url.pathname === "/join") kind = "provider-share";
      else return null;
      encoded = url.searchParams.get("invitation");
      base = server(url.searchParams.get("server"));
    } else {
      const match = /\/api\/agent-net\/(shared-task|provider-share)\/join$/.exec(url.pathname);
      if (!match || url.search) return null;
      kind = match[1];
      const [value, hint, extra] = url.hash.slice(1).split("?");
      if (extra !== void 0 || hint !== void 0 && !/^app=(cindy|cindycn|cindydev)$/.test(hint)) return null;
      encoded = value;
      base = server(url.origin + url.pathname.slice(0, -match[0].length));
    }
    const receipt = decodeAgentNetSharingInvitation(encoded);
    return base && receipt?.kind === kind && (!expectedKind || kind === expectedKind) ? { server: base, receipt } : null;
  } catch {
    return null;
  }
}

// .cache/shared-task-portable-91179cedad/packages/agent-net/src/socketEvents.ts
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

// .cache/shared-task-portable-91179cedad/packages/agent-net/src/portableClient.ts
var UDP_RELAY_HEADER = "x-agent-net-udp";
var UDP_RELAY_VERSION = "2";
function udpCredentialsAllowed(wsUrl) {
  return /^wss:\/\//i.test(wsUrl) || /^ws:\/\/(127\.0\.0\.1|localhost|\[::1\])(:\d+)?(\/|$)/i.test(wsUrl);
}
function udpCredentials(value) {
  if (!value || typeof value !== "object") return null;
  const { session, key: key3, probe } = value;
  if (typeof session !== "string" || typeof key3 !== "string") return null;
  try {
    const sessionBytes = fromBase64Url(session), keyBytes = fromBase64Url(key3);
    if (sessionBytes.length !== 8 || keyBytes.length !== 32) return null;
    return probe === true ? { session: sessionBytes, key: keyBytes, probe: true } : { session: sessionBytes, key: keyBytes };
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
var RELAY_QUEUE_STALL_MS = 1e3;
var RELAY_SEND_DEAD_MS = 45e3;
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
function bufferedBytes(ws) {
  return typeof ws.bufferedAmount === "number" && Number.isFinite(ws.bufferedAmount) && ws.bufferedAmount > 0 ? ws.bufferedAmount : 0;
}
var RELAY_PROBE_TIMEOUT_MS = 15e3;
var PortableUplink = class _PortableUplink extends SocketEvents {
  constructor(ws) {
    super();
    __publicField(this, "ws", ws);
    __publicField(this, "kind", "agent-net");
    __publicField(this, "devices", []);
    __publicField(this, "delegations", []);
    __publicField(this, "delegationRequests", []);
    __publicField(this, "notifications", false);
    __publicField(this, "supportsRelayProbe", false);
    __publicField(this, "probeTimer", null);
    __publicField(this, "lastProbeAt", -Infinity);
    /** This session's relay UDP credentials when the relay offered them; null keeps every relayed datagram on the WebSocket. */
    __publicField(this, "udp", null);
    __publicField(this, "receiver", null);
    __publicField(this, "pending", []);
    __publicField(this, "pendingBytes", 0);
    __publicField(this, "queues", /* @__PURE__ */ new Map());
    __publicField(this, "queuedBytes", 0);
    __publicField(this, "scheduled", null);
    __publicField(this, "stallSince", null);
    __publicField(this, "deadTimer", null);
    __publicField(this, "closed", false);
    __publicField(this, "closeEmitted", false);
  }
  probeRelay() {
    const now2 = performance.now();
    if (!this.supportsRelayProbe || this.closed || this.probeTimer || now2 - this.lastProbeAt < RELAY_PROBE_TIMEOUT_MS) return;
    this.lastProbeAt = now2;
    this.probeTimer = setTimeout(() => {
      this.probeTimer = null;
      if (performance.now() - now2 > 2 * RELAY_PROBE_TIMEOUT_MS) return;
      this.close();
      this.emitClose(1006);
    }, RELAY_PROBE_TIMEOUT_MS);
    try {
      this.ws.send('{"type":"relay-probe"}');
    } catch {
      this.close();
      this.emitClose(1006);
    }
  }
  clearProbe() {
    if (this.probeTimer !== null) clearTimeout(this.probeTimer);
    this.probeTimer = null;
  }
  emitClose(code) {
    if (this.closeEmitted) return;
    this.closeEmitted = true;
    this.emit("close", code);
  }
  clearStall() {
    this.stallSince = null;
    if (this.deadTimer) {
      clearTimeout(this.deadTimer);
      this.deadTimer = null;
    }
  }
  armDeadCheck() {
    if (this.deadTimer || this.closed) return;
    this.deadTimer = setTimeout(() => {
      this.deadTimer = null;
      if (this.closed || this.stallSince === null) return;
      if (bufferedBytes(this.ws) === 0) {
        this.stallSince = null;
        return;
      }
      const elapsed = performance.now() - this.stallSince;
      if (elapsed >= RELAY_SEND_DEAD_MS) {
        this.close();
        this.emitClose(1006);
        return;
      }
      this.armDeadCheck();
    }, Math.max(50, RELAY_SEND_DEAD_MS - (this.stallSince === null ? 0 : performance.now() - this.stallSince)));
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
        if (established && ws.readyState === 3) queueMicrotask(() => uplink.emitClose(1006));
      };
      let chain = Promise.resolve(), waiting = 0;
      ws.onerror = (event) => {
        const status = typeof event.message === "string" ? /\b(401|403)\b/.exec(event.message)?.[1] : void 0;
        fail(new Error(status ? "AGENT_NET_UPGRADE_" + status : "AGENT_NET_SOCKET_ERROR"));
      };
      ws.onclose = (event) => {
        clearTimeout(timer);
        if (!established) reject(new Error("AGENT_NET_CLOSED_" + event.code));
        uplink.clearProbe();
        uplink.closed = true;
        uplink.clearStall();
        if (established) uplink.emitClose(event.code);
      };
      ws.onmessage = (event) => {
        if (uplink.closed) return;
        if (bufferedBytes(ws) === 0) uplink.clearStall();
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
            if (message.type === "relay-pong" && receivedHello && uplink.supportsRelayProbe) {
              uplink.clearProbe();
              return;
            }
            const requests = message.delegationRequests ?? [];
            if (!["hello", "directory"].includes(message.type) || !Array.isArray(message.devices) || !Array.isArray(message.delegations) || !Array.isArray(requests) || !client.trustedDirectory(message.devices, message.delegations, requests)) throw new Error("UNTRUSTED_DIRECTORY");
            uplink.devices = message.devices;
            uplink.delegations = message.delegations;
            uplink.delegationRequests = requests;
            if (message.type === "hello") {
              if (receivedHello || message.protocolVersion !== 2 || message.deviceId !== (client.delegation ? "guest:" + client.delegation.id : client.identity.deviceId)) throw new Error("INVALID_HELLO");
              uplink.supportsRelayProbe = !client.delegation && message.relayProbe === true;
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
          if (batch.length && !this.closed && this.ws.readyState === 1) {
            const bufferedBefore = bufferedBytes(this.ws);
            if (bufferedBefore === 0) this.clearStall();
            else if (this.stallSince === null) {
              this.stallSince = performance.now();
              this.armDeadCheck();
            } else if (performance.now() - this.stallSince >= RELAY_SEND_DEAD_MS) {
              this.close();
              this.emitClose(1006);
              return;
            }
            const stalled = this.stallSince !== null && performance.now() - this.stallSince >= RELAY_QUEUE_STALL_MS;
            if (!stalled && bufferedBefore <= 1024 * 1024) {
              try {
                this.ws.send(encodeDatagrams(id, batch));
                if (bufferedBytes(this.ws) > 0 && this.stallSince === null) {
                  this.stallSince = performance.now();
                  this.armDeadCheck();
                }
              } catch {
              }
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
    this.clearProbe();
    if (this.closed) return;
    this.closed = true;
    this.clearStall();
    if (this.scheduled) clearTimeout(this.scheduled);
    this.scheduled = null;
    this.pending = [];
    this.pendingBytes = 0;
    this.queues.clear();
    this.queuedBytes = 0;
    this.ws.close();
  }
};

// .cache/shared-task-portable-91179cedad/packages/agent-net/src/scopedRoutes.ts
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

// .cache/shared-task-portable-91179cedad/packages/agent-net/src/types.ts
var MAX_CHANNEL_PENDING_BYTES = 8 * 1024 * 1024;
var AGENT_NET_SESSION_V1 = "agent-net-session-v1";
var SESSION_LANE_KINDS = { control: 48, normal: 49, background: 50 };
var SESSION_LANE_PRIORITY = { control: "interactive", normal: "normal", background: "background" };
var MAX_EARLY_SESSION_BYTES = 16 * 1024 * 1024;
var AGENT_NET_SESSION_V2 = "agent-net-session-v2";
var SESSION_BODY_KIND = 51;
var SESSION_BODY_HEADER_BYTES = 5;
var EARLY_BODY_EVENT_BYTES = 64;
var DRAIN_LOW_WATER_BYTES = 128 * 1024;
function classifyNatMapping(observations, localPort) {
  if (!observations.length) return { natMapping: "unknown", portPreserving: null };
  const ips = new Set(observations.map((entry) => entry.address));
  const ports = new Set(observations.map((entry) => entry.port));
  const portPreserving = typeof localPort === "number" && localPort > 0 ? observations.every((entry) => entry.port === localPort) : null;
  if (observations.length === 1) return { natMapping: "single-server", portPreserving };
  if (ips.size > 1) return { natMapping: "multi-egress", portPreserving };
  if (ports.size > 1) return { natMapping: "symmetric", portPreserving: false };
  return { natMapping: "cone", portPreserving };
}
function formatTransportDiagnosticsLog(diagnostics) {
  return `agent-net nat=${diagnostics.natMapping} portPreserving=${diagnostics.portPreserving === null ? "unknown" : String(diagnostics.portPreserving)} stun=${diagnostics.stunResponses} portMap=${diagnostics.portMapped ?? "none"} candidates=public:${diagnostics.publicCandidates},local:${diagnostics.localCandidates}`;
}
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

// .cache/shared-task-portable-91179cedad/packages/agent-net/src/session/binarySegments.ts
var BINARY_MIN_CHARS = 16 * 1024;
var MAX_BINARY_SEGMENTS = 4096;
var MARK = "\0b";
var SEGMENT = MARK + "#";
var ESCAPED = MARK + "=";
var ALPHABET2 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
var INDEX = new Int16Array(128).fill(-1);
for (let index = 0; index < ALPHABET2.length; index++) INDEX[ALPHABET2.charCodeAt(index)] = index;
function isStrictBase64Chars(text) {
  const padding = text.endsWith("==") ? 2 : text.endsWith("=") ? 1 : 0;
  const end = text.length - padding;
  for (let index = 0; index < end; index++) {
    const code = text.charCodeAt(index);
    if (code >= 128 || INDEX[code] < 0) return false;
  }
  return true;
}
function base64Codec(platform) {
  const { Buffer: NodeBuffer, atob: atobFn, btoa: btoaFn } = platform;
  const canonicalBase64Bytes2 = (text) => {
    if (text.length % 4 !== 0 || !isStrictBase64Chars(text)) return null;
    const padding = text.endsWith("==") ? 2 : text.endsWith("=") ? 1 : 0;
    if (padding) {
      const last = INDEX[text.charCodeAt(text.length - padding - 1)];
      if ((last & (padding === 2 ? 15 : 3)) !== 0) return null;
    }
    if (NodeBuffer) {
      const bytes = NodeBuffer.from(text, "base64");
      return new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    }
    const length = text.length / 4 * 3 - padding, out = new Uint8Array(length);
    if (atobFn) {
      const binary = atobFn(text);
      for (let index = 0; index < length; index++) out[index] = binary.charCodeAt(index);
      return out;
    }
    for (let at = 0, offset = 0; at < text.length; at += 4) {
      const value = INDEX[text.charCodeAt(at)] << 18 | INDEX[text.charCodeAt(at + 1)] << 12 | (INDEX[text.charCodeAt(at + 2)] & 63) << 6 | INDEX[text.charCodeAt(at + 3)] & 63;
      out[offset++] = value >> 16;
      if (offset < length) out[offset++] = value >> 8 & 255;
      if (offset < length) out[offset++] = value & 255;
    }
    return out;
  };
  const base64Of2 = (bytes) => {
    if (NodeBuffer) return NodeBuffer.from(bytes).toString("base64");
    if (btoaFn) {
      const parts2 = [];
      for (let at = 0; at < bytes.length; at += 8192) parts2.push(String.fromCharCode.apply(null, bytes.subarray(at, at + 8192)));
      return btoaFn(parts2.join(""));
    }
    const parts = [], codes = [];
    for (let at = 0; at < bytes.length; at += 3) {
      const a = bytes[at], b = bytes[at + 1], c = bytes[at + 2];
      codes.push(
        ALPHABET2.charCodeAt(a >> 2),
        ALPHABET2.charCodeAt((a & 3) << 4 | (b ?? 0) >> 4),
        b === void 0 ? 61 : ALPHABET2.charCodeAt((b & 15) << 2 | (c ?? 0) >> 6),
        c === void 0 ? 61 : ALPHABET2.charCodeAt(c & 63)
      );
      if (codes.length >= 8192) {
        parts.push(String.fromCharCode(...codes));
        codes.length = 0;
      }
    }
    if (codes.length) parts.push(String.fromCharCode(...codes));
    return parts.join("");
  };
  return { canonicalBase64Bytes: canonicalBase64Bytes2, base64Of: base64Of2 };
}
var { canonicalBase64Bytes, base64Of } = base64Codec(globalThis);
function hasBase64Run(text) {
  for (let index = 0, run = 0; index < text.length; index++) {
    const code = text.charCodeAt(index);
    if (code < 128 && INDEX[code] >= 0) {
      if (++run >= BINARY_MIN_CHARS) return true;
    } else run = 0;
  }
  return false;
}
function extractSegments(message, json) {
  if (json.length < BINARY_MIN_CHARS || !hasBase64Run(json)) return { json, segments: [] };
  const segments = [];
  const out = JSON.stringify(message, (_key, value) => {
    if (typeof value !== "string") return value;
    if (value.length >= BINARY_MIN_CHARS && segments.length < MAX_BINARY_SEGMENTS) {
      const bytes = canonicalBase64Bytes(value);
      if (bytes) {
        segments.push(bytes);
        return SEGMENT + (segments.length - 1);
      }
    }
    return value.startsWith(MARK) ? ESCAPED + value : value;
  });
  return segments.length ? { json: out, segments } : { json, segments: [] };
}
function restoreSegments(json, segments) {
  return JSON.parse(json, (_key, value) => {
    if (typeof value !== "string" || !value.startsWith(MARK)) return value;
    if (value.startsWith(ESCAPED)) return value.slice(ESCAPED.length);
    const index = value.startsWith(SEGMENT) ? Number(value.slice(SEGMENT.length)) : NaN;
    if (!Number.isInteger(index) || index < 0 || index >= segments.length || String(index) !== value.slice(SEGMENT.length)) {
      throw new Error("AGENT_NET_SESSION_FRAME_INVALID");
    }
    return base64Of(segments[index]);
  });
}

// .cache/shared-task-portable-91179cedad/packages/agent-net/src/session/lanes.ts
var SESSION_LANES = ["control", "normal", "background"];
var MAX_SESSION_MESSAGE_BYTES = 16 * 1024 * 1024;
var BULK_REQUEST_BYTES = 256 * 1024;
var MAX_SESSION_HELD_BYTES = 64 * 1024 * 1024;
var BODY_STREAM_BYTES = 64 * 1024;
var MAX_ABANDONABLE_BODIES = 256;
var MAX_OPEN_BODIES = 1024;
var MAX_ABANDONED_KEYS = 1024;
var LANE_INDEX = { control: 0, normal: 1, background: 2 };
var encoder = new TextEncoder();
var decoder = new TextDecoder();
function isCount(value) {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}
function isFrame(value, lane) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const { m, c, p, r, b, o, z, i, x, y } = value;
  if (x !== void 0) return c === "control" && lane === "control" && m === void 0 && z === void 0 && isCount(x) && x > 0;
  return (c === "control" || c === "request" || c === "result" || c === "push") && (p === void 0 || Array.isArray(p) && p.length === SESSION_LANES.length && p.every(isCount)) && (r === void 0 || isCount(r)) && (b === void 0 || isCount(b)) && (o === void 0 || o === 1 && c === "request" && lane === "background") && (z === void 0 || m === void 0 && Array.isArray(z) && z.length === 2 && z.every(isCount) && z[1] <= MAX_SESSION_MESSAGE_BYTES) && (i === void 0 || z !== void 0 && c === "result" && typeof i === "string" && i.length <= 256) && (y === void 0 || z !== void 0 && Array.isArray(y) && y.length >= 2 && y.length <= MAX_BINARY_SEGMENTS + 1 && y.every(isCount) && y.reduce((total, part) => total + part, 0) === z[1]);
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
    /** Session v2. Keys this side gives its bodies; started at random so a new session on the same connection does not reuse one. */
    __publicField(this, "nextBodyKey", 1 + Math.floor(Math.random() * 1073741823));
    __publicField(this, "outgoingBodies", /* @__PURE__ */ new Map());
    __publicField(this, "inboundBodies", /* @__PURE__ */ new Map());
    /**
     * Bodies the peer gave up (`x`). The notice may come before the placeholder or the body's first bytes, or after the body was
     * handed over, and the core still resends bytes of it already sent: anything that arrives for these keys is dropped, and a
     * placeholder for one is skipped. Bounded and never an error, so notices for bodies long handed over cost nothing.
     */
    __publicField(this, "abandonedKeys", /* @__PURE__ */ new Set());
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
    const json = JSON.stringify(message);
    const encodeFrame = () => encoder.encode(json === void 0 ? JSON.stringify(frame) : `{"m":${json},${JSON.stringify({ ...frame, m: void 0 }).slice(1)}`);
    let body = encodeFrame();
    let moved = false;
    if (kind === "request" && lane !== "background" && body.length > BULK_REQUEST_BYTES) {
      lane = "background";
      moved = true;
      frame.r = this.sentNormalRequests;
      delete frame.b;
      if (!options.unordered) frame.o = 1;
      body = encodeFrame();
    }
    const index = LANE_INDEX[lane];
    if (body.length > MAX_SESSION_MESSAGE_BYTES) throw new Error("PAYLOAD_TOO_LARGE");
    if (body.length >= BODY_STREAM_BYTES && json !== void 0 && this.options.openBody) {
      const key3 = this.nextBodyKey;
      const writer = this.options.openBody(lane, key3);
      if (writer) {
        this.nextBodyKey = this.nextBodyKey >= 2147483647 ? 1 : this.nextBodyKey + 1;
        const { json: text, segments } = extractSegments(message, json);
        const content = encoder.encode(text);
        const total = segments.reduce((sum, segment) => sum + segment.length, content.length);
        const { m: _message, ...stamps } = frame;
        const stub = {
          ...stamps,
          z: [key3, total],
          ...kind === "result" && options.id ? { i: options.id } : {},
          ...segments.length ? { y: [content.length, ...segments.map((segment) => segment.length)] } : {}
        };
        this.writeFrame(lane, encoder.encode(JSON.stringify(stub)));
        writer.write(content);
        for (const segment of segments) writer.write(segment);
        writer.finish();
        if (kind === "result" && options.id) {
          if (this.outgoingBodies.size >= MAX_ABANDONABLE_BODIES) this.outgoingBodies.delete(this.outgoingBodies.keys().next().value);
          this.outgoingBodies.set(options.id, { writer, key: key3 });
        }
        this.counted(kind, lane, index, moved, options);
        return lane;
      }
    }
    this.writeFrame(lane, body);
    this.counted(kind, lane, index, moved, options);
    return lane;
  }
  writeFrame(lane, body) {
    const bytes = new Uint8Array(4 + body.length);
    new DataView(bytes.buffer).setUint32(0, body.length, false);
    bytes.set(body, 4);
    this.options.write(lane, bytes);
  }
  counted(kind, lane, index, moved, options) {
    if (kind === "push") this.sentPushes[index]++;
    if (kind === "request" && lane === "normal") this.sentNormalRequests++;
    if (moved && !options.unordered) this.sentMovedRequests++;
  }
  /**
   * Session v2: the caller of request `id` gave up. If its result is still being written as a body, the rest is not sent; the peer
   * sees the body end short and skips the result (its caller is no longer waiting). False when there is no such body.
   */
  abandonResult(id) {
    const body = this.outgoingBodies.get(id);
    if (!body) return false;
    this.outgoingBodies.delete(id);
    body.writer.abandon();
    if (!this.closed) this.writeFrame("control", encoder.encode(JSON.stringify({ c: "control", x: body.key })));
    return true;
  }
  /**
   * Session v2: bytes of a body stream the peer opened (`key` from its first bytes; any chunking), then `null` when the stream
   * ended. Keeps `bytes` until the body is handed over, like `receive`.
   */
  receiveBody(key3, bytes) {
    if (this.closed || this.abandonedKeys.has(key3)) return;
    let body = this.inboundBodies.get(key3);
    if (!body) {
      if (bytes === null) return;
      if (this.inboundBodies.size >= MAX_OPEN_BODIES) {
        this.fail(new Error("AGENT_NET_SESSION_BACKLOG"));
        return;
      }
      body = { chunks: [], length: 0, ended: false };
      this.inboundBodies.set(key3, body);
    }
    if (bytes === null) {
      body.ended = true;
      this.pump();
      return;
    }
    if (body.ended) {
      this.fail(new Error("AGENT_NET_SESSION_FRAME_INVALID"));
      return;
    }
    if (!bytes.length) return;
    body.chunks.push(bytes);
    body.length += bytes.length;
    this.heldBytes += bytes.length;
    if (body.length > (body.total ?? MAX_SESSION_MESSAGE_BYTES)) {
      this.fail(new Error("AGENT_NET_SESSION_FRAME_TOO_LARGE"));
      return;
    }
    if (this.heldBytes > MAX_SESSION_HELD_BYTES) {
      this.fail(new Error("AGENT_NET_SESSION_BACKLOG"));
      return;
    }
    if (body.id !== void 0) this.options.onProgress?.(body.id, body.length, body.total);
    if (body.length === body.total) this.pump();
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
      if (frame.x !== void 0) {
        this.bodyAbandoned(frame.x);
        continue;
      }
      if (frame.z && !this.expectBody(frame)) return;
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
    this.inboundBodies.clear();
    this.outgoingBodies.clear();
    this.abandonedKeys.clear();
    this.heldBytes = 0;
  }
  /** The sender gave up the body with this key: its placeholder is skipped when it reaches its lane's head (or as soon as it arrives). */
  bodyAbandoned(key3) {
    if (this.abandonedKeys.size >= MAX_ABANDONED_KEYS) this.abandonedKeys.delete(this.abandonedKeys.values().next().value);
    this.abandonedKeys.add(key3);
    const body = this.inboundBodies.get(key3);
    if (!body) return;
    this.heldBytes -= body.length;
    body.chunks = [];
    body.length = 0;
    body.ended = true;
  }
  /** A placeholder named its body: its length (and the result's id) applies to the bytes from now on. False: the session failed. */
  expectBody(frame) {
    const [key3, total] = frame.z;
    let body = this.inboundBodies.get(key3);
    if (!body) {
      if (this.inboundBodies.size >= MAX_OPEN_BODIES) {
        this.fail(new Error("AGENT_NET_SESSION_BACKLOG"));
        return false;
      }
      body = { chunks: [], length: 0, ended: false };
      this.inboundBodies.set(key3, body);
    }
    if (body.total !== void 0 || body.length > total) {
      this.fail(new Error("AGENT_NET_SESSION_FRAME_INVALID"));
      return false;
    }
    body.total = total;
    if (this.abandonedKeys.has(key3)) {
      body.ended = true;
      return true;
    }
    body.id = frame.i;
    if (body.id !== void 0 && body.length > 0) this.options.onProgress?.(body.id, body.length, total);
    return true;
  }
  ready(lane, frame) {
    if (frame.z) {
      const body = this.inboundBodies.get(frame.z[0]);
      if (!body || !body.ended && body.length < frame.z[1]) return false;
    }
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
            let message = head.frame.m;
            if (head.frame.z) {
              const [key3, total] = head.frame.z;
              const body = this.inboundBodies.get(key3);
              this.inboundBodies.delete(key3);
              this.heldBytes -= body.length;
              if (body.length < total) {
                this.delivered(lane, head.frame);
                this.pumpAgain = true;
                continue;
              }
              try {
                const bytes = join(body.chunks, body.length), y = head.frame.y;
                if (!y) message = JSON.parse(decoder.decode(bytes));
                else {
                  const segments = [];
                  for (let index = 1, offset = y[0]; index < y.length; offset += y[index], index++) segments.push(bytes.subarray(offset, offset + y[index]));
                  message = restoreSegments(decoder.decode(bytes.subarray(0, y[0])), segments);
                }
              } catch {
                this.fail(new Error("AGENT_NET_SESSION_FRAME_INVALID"));
                return;
              }
            }
            state.busy = true;
            let result = void 0;
            try {
              result = this.options.deliver(message, SESSION_LANES[lane]);
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
function join(chunks, length) {
  if (chunks.length === 1) return chunks[0];
  const out = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}
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

// .cache/shared-task-portable-91179cedad/packages/agent-net/src/session/peer.ts
var SENDS = {
  call: /* @__PURE__ */ new Set(["open", "invoke", "cancel", "close"]),
  serve: /* @__PURE__ */ new Set(["accept", "reject", "result", "push", "close"])
};
var RECEIVES = { call: SENDS.serve, serve: SENDS.call };
var RESULT_STALL_MS = 15e3;
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
    /** When bytes of anything last arrived on this session (lanes or bodies). */
    __publicField(this, "receivedAt", 0);
    /** Session v2: requests with the business whose caller gave up: their result is not sent (results wait on no count). */
    __publicField(this, "cancelledInFlight", /* @__PURE__ */ new Set());
    /**
     * Smallest (this side's clock when a request arrived − the sender's clock when it wrote it) on this session: the offset
     * between the two clocks plus the fastest trip. How much later than that a request arrives is how long it was held up
     * (a stalled path, a retransmission, a wait in this side's lane queue); neither clock has to agree with the other.
     */
    __publicField(this, "lagFloor", null);
    /** Receiver clock minus sender clock, measured from an authenticated link acceptance. Travel time makes this a lower bound. */
    __publicField(this, "peerClockLowerBound");
    const openBody = options.bodies ? options.wire.openBody?.bind(options.wire) : void 0;
    this.lanes = new SessionLanes({
      write: (lane, bytes) => options.wire.write(lane, bytes),
      deliver: (message, lane) => this.deliver(message, lane),
      onError: (error) => this.dispose(error.message),
      ...openBody ? { openBody } : {},
      onProgress: (id, received, total) => this.progress(id, received >= total)
    });
    options.wire.onData((lane, bytes) => {
      this.receivedAt = performance.now();
      this.lanes.receive(lane, bytes);
    });
    options.wire.onBody?.((key3, bytes) => {
      this.receivedAt = performance.now();
      this.lanes.receiveBody(key3, bytes);
    });
    options.wire.onDrain?.(() => options.onDrain?.());
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
      try {
        this.send("control", "control", { t: "open", id, payload });
      } catch (error) {
        if (!this.opening.delete(id)) return;
        clearTimeout(timer);
        refused(error instanceof Error ? error : new Error(String(error)));
      }
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
        entry.timer = setTimeout(() => this.expire(id, entry, `no result within ${timeoutMs}ms`), timeoutMs);
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
    if (this.cancelledInFlight.delete(id)) {
      this.inboundLane.delete(id);
      return;
    }
    const lane = this.inboundLane.get(id) ?? "normal";
    this.send(lane, "result", { t: "result", id, result }, { id });
    this.inboundLane.delete(id);
  }
  cancelRequest(id) {
    const entry = this.pending.get(id);
    if (entry) this.expire(id, entry, "request was cancelled");
  }
  /** The request timed out (`INVOKE_TIMEOUT`, it may have run): tell the peer, so it does not start it or stops sending its result. */
  expire(id, entry, message) {
    if (this.pending.get(id) !== entry) return;
    this.pending.delete(id);
    if (entry.timer) clearTimeout(entry.timer);
    if (entry.written && !this.broken) {
      try {
        this.send("control", "control", { t: "cancel", id });
      } catch {
      }
    }
    entry.resolve(failure("INVOKE_TIMEOUT", message));
  }
  /**
   * Session v2: bytes of the result for `id` arrived on its body stream; from now on only a stall fails it (RESULT_STALL_MS). Once all
   * of it arrived it waits for what is before it on its lane (a larger result still arriving, v1 order): then it fails only if nothing
   * at all arrives on the session for that long.
   */
  progress(id, complete) {
    const entry = this.pending.get(id);
    if (!entry) return;
    const first = entry.progressAt === void 0;
    entry.progressAt = performance.now();
    entry.complete || (entry.complete = complete);
    if (!first || !entry.timer) return;
    clearTimeout(entry.timer);
    const check2 = () => {
      const idle = performance.now() - (entry.complete ? Math.max(entry.progressAt, this.receivedAt) : entry.progressAt);
      if (idle >= RESULT_STALL_MS) this.expire(id, entry, `result stalled for ${RESULT_STALL_MS}ms`);
      else entry.timer = setTimeout(check2, RESULT_STALL_MS - idle);
    };
    entry.timer = setTimeout(check2, RESULT_STALL_MS);
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
    this.cancelledInFlight.clear();
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
        if (typeof message.id !== "string") return;
        if (this.lanes.abandonResult(message.id)) return;
        if (this.inboundLane.has(message.id)) {
          if (this.options.bodies) {
            if (this.cancelledInFlight.size >= MAX_CANCELLED_REQUESTS) this.cancelledInFlight.delete(this.cancelledInFlight.values().next().value);
            this.cancelledInFlight.add(message.id);
          }
          return;
        }
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

// .cache/shared-task-portable-91179cedad/packages/agent-net/src/portableSocket.ts
var REDIAL_TAKEOVER_MS = 1e4;
var REDIAL_FIRST_MS = 1e3;
var REDIAL_MAX_MS = 3e4;
var RELAY_STABLE_MS = 1e4;
var LATE_DIAL_MS = 1e3;
var EARLY_DATAGRAMS = 32;
var REMEMBERED_CANDIDATE_DIAL_MS = 350;
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
    __publicField(this, "early", []);
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
    /**
     * From opening until this socket has dialed from its first live directory. A socket that has just opened is the one side
     * that knows there is no connection: the process started, or the phone came back and opened a new socket. The devices
     * already there may still hold their end of the connection the previous socket had (LATE_DIAL_MS) and then do not dial,
     * so this side dials every device the directory has online, whatever the ids, and waits for nobody. 2026-11-21, a phone
     * whose id is higher than every computer's: not one of seven computers dialed it within the 0.8 to 1.2 seconds it then
     * waited, on any cold start or return to the foreground; the same phone with a lower id was connected 0.9 seconds sooner.
     * A device that is dialing this one at the same moment ends up on one connection as any simultaneous dial does (`adopt`).
     */
    __publicField(this, "arriving", true);
    __publicField(this, "localHello", null);
    __publicField(this, "reconnect", null);
    __publicField(this, "generation", 0);
    __publicField(this, "retryMs", 500);
    __publicField(this, "duplicateIdentityCooldown", false);
    __publicField(this, "replacementStreak", 0);
    __publicField(this, "replacedReconnectUntil", 0);
    __publicField(this, "rosterValidUntil", 0);
    __publicField(this, "lan", null);
    __publicField(this, "lanCandidates", /* @__PURE__ */ new Map());
    __publicField(this, "rememberedCandidates", /* @__PURE__ */ new Set());
    __publicField(this, "peerPathPreferences", /* @__PURE__ */ new Map());
    __publicField(this, "openingRelay", null);
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
    if (options.initialPeerPathPreferences) {
      for (const [id, pref] of Object.entries(options.initialPeerPathPreferences)) {
        if (pref === "direct" || pref === "relay") socket.peerPathPreferences.set(id, pref);
      }
    }
    socket.updateDirectory((options.cachedDirectory ?? []).map((view) => ({ ...view, online: false })), false);
    for (const [id, address] of options.initialCandidates ?? []) {
      if (socket.authorized(id)) {
        socket.lanCandidates.set(id, address);
        socket.rememberedCandidates.add(id);
      }
    }
    let relayError;
    let relayDone = null;
    if (!options.deferRelay || socket.roster.size === 0) {
      try {
        await socket.connectRelay();
      } catch (error) {
        if (socket.closed || socket.roster.size === 0) {
          socket.close();
          throw error;
        }
        socket.scheduleReconnect();
      }
    } else {
      let finishOpeningRelay;
      socket.openingRelay = new Promise((resolve) => {
        finishOpeningRelay = resolve;
      });
      relayDone = socket.connectRelay().then(() => {
        socket.openingRelay = null;
        finishOpeningRelay();
      }, (error) => {
        relayError = error;
        socket.openingRelay = null;
        finishOpeningRelay();
        if (socket.ready && !socket.closed) {
          for (const [id, view] of socket.roster) {
            if (id !== socket.deviceId && !socket.peers.has(id) && !socket.dialing.has(id) && !socket.lanCandidates.has(id) && !(view.online && socket.memberAccepted(id))) {
              socket.presence(id, false);
            }
          }
        }
        if (!socket.closed && socket.roster.size > 0) socket.scheduleReconnect();
      });
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
        onLocalPortChanged: (port, reason) => {
          const currentDial = socket.transport?.dial;
          if (currentDial?.udp) currentDial.udp = { ...currentDial.udp, port };
          socket.lan?.updatePort?.(port);
          options.onUdpRebound?.(reason);
        },
        onIncoming: (channel) => socket.adopt(channel, false)
      });
      socket.uplink?.onDatagram((id, data) => socket.receive(id, data));
      const early = socket.early ?? [];
      socket.early = null;
      for (const { id, data } of early) socket.receiveDatagram?.(id, data);
      const dial = socket.transport.dial;
      if (options.bindings.createDiscovery && options.lanDiscovery !== false && dial.udp && !options.client.delegation) {
        socket.lan = options.bindings.createDiscovery({
          networkId: options.client.certificate.networkId,
          port: dial.udp.port,
          certificateFor: (id) => socket.authorized(id) ? socket.roster.get(id)?.certificate : void 0,
          onCandidate(id, address) {
            if (!socket.authorized(id)) return;
            socket.rememberedCandidates.delete(id);
            socket.lanCandidates.set(id, address);
            options.onDirectAddress?.(id, address);
            if (socket.ready && !socket.peers.has(id)) void socket.dial(id).catch(() => void 0);
          }
        });
        socket.lan.start();
      }
      if (relayDone) {
        if (relayError !== void 0 && socket.closed) {
          socket.close();
          throw relayError;
        }
        for (const id of socket.lanCandidates.keys()) {
          if (!socket.peers.has(id)) void socket.dial(id).catch(() => {
            if (!socket.openingRelay && !socket.peers.has(id) && !socket.roster.get(id)?.online) socket.presence(id, false);
          });
        }
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
    if (!this.options.client.delegation && this.roster.has(key3) && this.sessionScope(key3) && !this.peers.has(key3) && !this.dialing.has(key3) && !this.lanCandidates.has(key3) && this.roster.get(key3).online !== true && this.openingRelay) {
      await this.openingRelay;
      if (this.closed || !this.sessionConfig) return false;
    }
    const deviceId = this.sessions.get(key3)?.deviceId ?? (this.options.client.delegation ? this.scopedPeerTarget(key3)?.relayId : this.roster.has(key3) && this.sessionScope(key3) && (this.peers.has(key3) || this.dialing.has(key3) || this.lanCandidates.has(key3) || this.roster.get(key3).online === true) ? key3 : void 0);
    if (!deviceId) return false;
    if (!this.peers.has(deviceId)) {
      try {
        await this.dial(deviceId);
      } catch {
        return this.peers.has(deviceId);
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
    peer.channel.declareSessions?.([...scope.role === "both" ? [SESSION_PRESENCE_FEATURE] : [], ...peer.channel.sessionBodies ? [AGENT_NET_SESSION_V2] : []]);
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
      const unauthorized = () => {
        queueMicrotask(() => session.dispose("UNAUTHORIZED"));
        return new Error("UNAUTHORIZED");
      };
      const checked = {
        write: (lane, bytes) => {
          if (!current()) throw unauthorized();
          wire.write(lane, bytes);
        },
        get bufferedAmount() {
          return wire.bufferedAmount;
        },
        onData: (handler) => wire.onData(handler),
        ...wire.openBody ? {
          openBody: (lane, key3) => {
            if (!current()) throw unauthorized();
            const body = wire.openBody(lane, key3);
            return body && {
              write: (bytes) => {
                if (!current()) throw unauthorized();
                body.write(bytes);
              },
              finish: () => body.finish(),
              abandon: () => body.abandon()
            };
          }
        } : {},
        ...wire.onBody ? { onBody: (handler) => wire.onBody(handler) } : {},
        ...wire.onDrain ? { onDrain: (handler) => wire.onDrain(handler) } : {}
      };
      const bodies = !!wire.openBody && peer.channel.sessionBodies === true && peer.channel.sessionFeatures?.().includes(AGENT_NET_SESSION_V2) === true;
      session = new SessionPeer({
        wire: checked,
        role: scope.role,
        laneFor: config.laneFor,
        bodies,
        onOpen: guard(handlers.onOpen),
        onClose: guard(handlers.onClose),
        onRequest: guard(handlers.onRequest),
        onPush: guard(handlers.onPush),
        onDrain: guard(handlers.onDrain),
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
  /** True while `connectSession` has an active or pending V2 path to try (connected, online, dialing/LAN candidate, or initial relay handshake opening). */
  canConnectSession(deviceId) {
    return this.supports(deviceId) || this.authorized(deviceId) && (this.dialing.has(deviceId) || this.lanCandidates.has(deviceId) || this.openingRelay !== null && this.roster.has(deviceId));
  }
  /** A previously certified V2 peer must not silently downgrade when its relay session disappears. */
  knowsPeer(deviceId) {
    return this.knownV2.has(deviceId);
  }
  /**
   * Every device `knowsPeer` is true for. The worker mirrors it to the thread that asks (`worker.ts` `snapshot`): a device
   * left out of the directory for sharing a transport key (`supersedes`) reaches that thread in no directory or path event.
   */
  knownPeers() {
    return [...this.knownV2];
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
    const resolvedId = this.sessionDevice(deviceId) ?? deviceId;
    const channel = this.peers.get(resolvedId)?.channel, path = channel?.path?.();
    if (!channel || !path) return null;
    const rtt = channel.stats?.()?.srttUs;
    const metrics = channel.pathMetrics?.();
    return {
      path,
      rttMs: typeof rtt === "number" && rtt > 0 ? rtt / 1e3 : null,
      ...metrics ? {
        directRttMs: metrics.directRttMs,
        relayRttMs: metrics.relayRttMs,
        pathPreference: this.peerPathPreferences.get(resolvedId) ?? metrics.preference,
        peerRelayVia: metrics.peerRelayVia ?? null
      } : {}
    };
  }
  setPeerPathPreference(deviceId, preference) {
    if (preference === "auto") this.peerPathPreferences.delete(deviceId);
    else this.peerPathPreferences.set(deviceId, preference);
    this.peers.get(deviceId)?.channel.setPathPreference?.(preference);
  }
  async dial(deviceId) {
    if (this.closed || this.peers.has(deviceId)) return;
    const existing = this.dialing.get(deviceId);
    if (existing) return existing;
    const key3 = this.transportKey(deviceId);
    if (!key3 || !this.authorized(deviceId)) throw new Error("UNAUTHORIZED_PEER");
    const lan = this.lanCandidates.get(deviceId);
    const remembered = lan !== void 0 && this.rememberedCandidates.has(deviceId);
    const entry = { id: keyHex(key3), dial: {
      relayId: deviceId,
      ...lan ? { udp: lan, preferUdp: true, ...remembered ? { timeoutMs: REMEMBERED_CANDIDATE_DIAL_MS } : {} } : {}
    } };
    const connect = async () => {
      try {
        return await this.transport.connect(entry);
      } catch (error) {
        if (lan && this.lanCandidates.get(deviceId) === lan) {
          this.lanCandidates.delete(deviceId);
          this.rememberedCandidates.delete(deviceId);
        }
        if (lan && !this.uplink && this.openingRelay) await this.openingRelay;
        if (!lan || !this.uplink || !this.authorized(deviceId) || keyHex(this.transportKey(deviceId)) !== entry.id) throw error;
        return this.transport.connect({ id: entry.id, dial: { relayId: deviceId } });
      }
    };
    const uplink = this.uplink;
    const dialing = connect().then((channel) => this.adopt(channel, true), (error) => {
      if (!this.closed && uplink === this.uplink && this.roster.get(deviceId)?.online && !this.peers.has(deviceId)) {
        uplink?.probeRelay?.();
      }
      throw error;
    });
    this.dialing.set(deviceId, dialing);
    try {
      await dialing;
    } finally {
      if (this.dialing.get(deviceId) === dialing) this.dialing.delete(deviceId);
    }
  }
  /**
   * See REDIAL_FIRST_MS and LATE_DIAL_MS: the dialing side (the lower id) dials again, the other side dials when that dial
   * does not come. Only devices of this account the directory has online; delegations dial on demand.
   */
  scheduleRedial(deviceId) {
    if (this.closed || this.redials.has(deviceId) || this.deviceId === deviceId) return;
    if (!this.roster.get(deviceId)?.online || !this.authorized(deviceId)) return;
    const step = this.redialSteps.get(deviceId) ?? 0;
    this.redialSteps.set(deviceId, step + 1);
    const first = this.deviceId < deviceId ? REDIAL_FIRST_MS : LATE_DIAL_MS;
    const delay = Math.min(REDIAL_MAX_MS, first * 2 ** step) * (0.8 + Math.random() * 0.4);
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
    const holders = /* @__PURE__ */ new Map(), ownKey = this.options.client.identity.transportKey;
    for (const view of next.values()) {
      const held = holders.get(view.certificate.transportKey);
      if (!held || this.supersedes(view.certificate, held.certificate)) holders.set(view.certificate.transportKey, view);
    }
    for (const [id, view] of [...next]) {
      const c = view.certificate;
      if (holders.get(c.transportKey) !== view || c.transportKey === ownKey && id !== this.deviceId) next.delete(id);
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
    this.transport?.admissionChanged?.();
    this.dropUnauthorizedPeers();
    if (live) this.options.onDirectory?.([...next.values()]);
    this.dialRoster();
  }
  /** Of two certificates of this account with one transport key: this device's own, else the one issued later (then the higher device id, so every device picks the same one). */
  supersedes(a, b) {
    if (a.deviceId === this.deviceId || b.deviceId === this.deviceId) return a.deviceId === this.deviceId;
    return a.issuedAt !== b.issuedAt ? a.issuedAt > b.issuedAt : a.deviceId > b.deviceId;
  }
  dropUnauthorizedPeers() {
    for (const id of this.lanCandidates.keys()) if (!this.authorized(id)) {
      this.lanCandidates.delete(id);
      this.rememberedCandidates.delete(id);
    }
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
    if (!this.ready) return;
    for (const [id, view] of this.roster) if (!this.peers.has(id)) {
      if (!this.openingRelay && !this.dialing.has(id) && !this.lanCandidates.has(id) && !(view.online && this.memberAccepted(id))) {
        this.presence(id, false);
      }
      this.dialOnline(id, view);
    }
    this.arrived();
  }
  /**
   * A device the directory has online and this side is not connected to: the lower id dials now, the other side if that
   * dial does not come (LATE_DIAL_MS). A socket that has just opened dials now whatever the ids (`arriving`).
   */
  dialOnline(id, view) {
    if (!view.online || id === this.deviceId || !this.memberAccepted(id)) return;
    const offlineIfUnconnected = () => {
      if (!this.peers.has(id)) this.presence(id, false);
    };
    if (this.deviceId < id || this.arriving) void this.dial(id).catch(() => {
      offlineIfUnconnected();
      this.scheduleRedial(id);
    });
    else this.scheduleRedial(id);
  }
  /** The directory just dialed from was the relay's, not the cached one a socket opens with while the relay is unreachable. */
  arrived() {
    if (this.uplink) this.arriving = false;
  }
  /**
   * A datagram from the relay. The relay announces this device to the others as soon as its connection is up, which is
   * before the transport exists (about 50 ms on a phone): a device that dials on that announcement has its first handshake
   * packet here by then. Dropped, as before 2026-11-21, its dial waited for the core to send the packet again (200 ms).
   */
  receive(id, data) {
    if (this.receiveDatagram) this.receiveDatagram(id, data);
    else if (this.early && this.early.length < EARLY_DATAGRAMS) this.early.push({ id, data });
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
  /** Updates the STUN server list (e.g. peer official region STUN discovered asynchronously). */
  setStunServers(servers) {
    if (this.closed) return;
    this.transport?.setStunServers?.(servers);
  }
  /** Session requests to a relayed peer timed out (see Transport.relayStalled). */
  relayStalled() {
    if (this.closed) return;
    this.transport?.relayStalled?.();
    if (this.transport?.relayRoute?.()?.via !== "udp") this.uplink?.probeRelay?.();
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
    if (Date.now() < this.replacedReconnectUntil) return;
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
  /**
   * The host holds no relay connection for this socket and has seen no attempt to make one for a long time (the Desktop's
   * watchdog, AGENT_NET_RELAY_STUCK_MS): whatever this socket still takes for its relay connection is dropped, an attempt
   * that never settled no longer counts, and a new one is scheduled. Peer connections stay. 2026-11-25: an uplink ended
   * without its close arriving here; this socket kept it as its relay connection and never reconnected until a restart.
   */
  restartRelay() {
    if (this.closed) return;
    const old = this.uplink;
    if (old) {
      this.uplink = null;
      old.close();
      if (this.ready) this.acknowledgeHello();
    }
    if (this.reconnect) {
      clearTimeout(this.reconnect);
      this.reconnect = null;
    }
    this.generation++;
    this.resendWhenRelayBack = true;
    this.scheduleReconnect();
  }
  /** See Transport.relayRoute (the worker reports it to the Desktop with each status snapshot). */
  relayRoute() {
    return this.closed ? null : this.transport?.relayRoute?.() ?? null;
  }
  /** Whether the relay WebSocket is currently up; false while offline or after an upgrade rejection fell back to cached directory. */
  relayConnected() {
    return !this.closed && this.uplink !== null;
  }
  setDuplicateIdentityCooldown(active) {
    this.duplicateIdentityCooldown = active;
    if (!active) {
      this.replacementStreak = 0;
      this.replacedReconnectUntil = 0;
    }
  }
  /** Resolves once the background initial relay connection attempt (`deferRelay`) finishes. */
  whenInitialRelaySettled() {
    return this.openingRelay ?? Promise.resolve();
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
    this.transport?.admissionChanged?.();
    this.dropUnauthorizedPeers();
    this.dialRoster();
  }
  async connectRelay() {
    const generation = ++this.generation;
    let uplink;
    try {
      uplink = await this.options.client.connect();
    } catch (error) {
      const message = error instanceof Error ? error.message : "";
      if (/^AGENT_NET_UPGRADE_(401|403)$/.test(message)) this.closeOnIdentityRefusal(message);
      throw error;
    }
    if (this.closed || generation !== this.generation) {
      uplink.close();
      return;
    }
    this.openingRelay = null;
    this.uplink = uplink;
    this.replacedReconnectUntil = 0;
    const connectedAt = Date.now();
    if (this.resendWhenRelayBack) {
      this.resendWhenRelayBack = false;
      this.transport?.networkChanged?.();
    }
    this.updateDirectory(uplink.devices, true, uplink.delegations ?? []);
    this.options.onDelegationRequests?.(uplink.delegationRequests ?? []);
    uplink.onDatagram((id, data) => this.receive(id, data));
    uplink.on("directory", () => {
      this.updateDirectory(uplink.devices, true, uplink.delegations ?? []);
      this.options.onDelegationRequests?.(uplink.delegationRequests ?? []);
    });
    uplink.once("close", (code, reason) => {
      if (this.uplink !== uplink || this.closed) return;
      this.uplink = null;
      if (Date.now() - connectedAt >= RELAY_STABLE_MS) this.retryMs = 500;
      this.options.onRelayClosed?.(code, reason);
      if ([4410, 4401, 4403].includes(code)) {
        this.closeOnIdentityRefusal("AGENT_NET_CLOSED_" + code);
        return;
      }
      if (code === 4409) {
        this.options.onRelayReplaced?.();
        if (this.duplicateIdentityCooldown) {
          if (Date.now() - connectedAt >= 5 * 6e4) this.replacementStreak = 0;
          const floor = computeDuplicateIdentityCooldownMs({ streak: ++this.replacementStreak, baseMs: 5e3, maxMs: 6e4 });
          this.replacedReconnectUntil = Date.now() + Math.round(floor * (0.7 + Math.random() * 0.3));
        }
      }
      if (code === 1006 && !reason) this.resendWhenRelayBack = true;
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
    }, Math.max(this.retryMs, this.replacedReconnectUntil - Date.now()));
    unrefTimer(this.reconnect);
    this.retryMs = Math.min(15e3, this.retryMs * 2);
  }
  send(text) {
    if (this.closed) throw new Error("AGENT_NET_SOCKET_CLOSED");
    if (utf8(text).length > MAX_FRAME_BYTES2) throw new Error("PAYLOAD_TOO_LARGE");
    const frame = JSON.parse(text);
    if (frame.v !== PROTOCOL_VERSION) throw new Error("VERSION_MISMATCH");
    if (!this.ready) {
      if (frame.kind !== "hello") return;
      this.localHello = frame.payload;
      this.ready = true;
      if (!this.options.client.delegation) this.uplink?.presence(this.localHello.remoteControlEnabled, this.localHello.capabilities ?? [], this.localHello);
      this.acknowledgeHello();
      for (const [id, view] of this.roster) if (id !== this.deviceId) {
        if (!this.openingRelay && !this.peers.has(id) && !this.dialing.has(id) && !this.lanCandidates.has(id) && !(view.online && this.memberAccepted(id))) {
          this.presence(id, false);
        }
        this.dialOnline(id, view);
      }
      this.arrived();
      for (const peer of this.peers.values()) {
        if (peer.info) this.deliver({ v: PROTOCOL_VERSION, kind: "presence-changed", payload: peer.info });
        this.sendPresence(peer);
      }
      for (const id of this.lanCandidates.keys()) if (!this.peers.has(id)) {
        void this.dial(id).catch(() => {
          if (!this.openingRelay && !this.peers.has(id) && !this.roster.get(id)?.online) this.presence(id, false);
        });
      }
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
    const savedPreference = this.peerPathPreferences.get(deviceId);
    if (savedPreference) channel.setPathPreference?.(savedPreference);
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
    const direct = channel.directAddress?.();
    if (direct) this.options.onDirectAddress?.(deviceId, direct);
    this.options.onPathChanged?.(deviceId, channel.path?.() ?? null);
    channel.onPathChange?.((path) => {
      if (this.peers.get(deviceId) !== peer) return;
      const updated = channel.directAddress?.();
      if (updated) this.options.onDirectAddress?.(deviceId, updated);
      this.options.onPathChanged?.(deviceId, path);
    });
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
    const prefix2 = new Uint8Array(4);
    new DataView(prefix2.buffer).setUint32(0, body.length, false);
    try {
      peer.channel.send(concatBytes([prefix2, body]));
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
  closeOnIdentityRefusal(reason) {
    const fallback = this.options.onIdentityRefused?.(reason) === true;
    this.close(fallback ? 1006 : 4410);
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
    this.rememberedCandidates.clear();
    this.openingRelay = null;
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

// .cache/shared-task-portable-91179cedad/packages/agent-net/src/pathRouter.ts
var STANDBY_INITIAL_MEASURE_MS = 2e3;
var PATH_RTT_STALE_MS = 12e4;
var AUTO_RELAY_MIN_DELTA_MS = 25;
var AUTO_RELAY_MAX_DELTA_MS = 50;
var AUTO_RELAY_RATIO_MARGIN = 0.25;
var AUTO_DIRECT_RECOVER_DELTA_MS = 15;
var AUTO_SWITCH_COOLDOWN_MS = 3e4;
var AUTO_EMERGENCY_RATIO = 2;
var AUTO_EMERGENCY_DELTA_MS = 100;
var AUTO_RELAY_RATIO = 1 + AUTO_RELAY_RATIO_MARGIN;
var PROBES_PER_ROUND = 4;
function autoRelaySwitchMarginMs(relayRttMs) {
  return Math.min(
    AUTO_RELAY_MAX_DELTA_MS,
    Math.max(AUTO_RELAY_MIN_DELTA_MS, relayRttMs * AUTO_RELAY_RATIO_MARGIN)
  );
}
function decideAutoPreferRelay(input) {
  const { currentPreferRelay, directRttMs, relayRttMs, msSinceLastSwitch } = input;
  if (directRttMs === null || relayRttMs === null) return currentPreferRelay;
  if (!currentPreferRelay) {
    const severe2 = directRttMs >= relayRttMs * AUTO_EMERGENCY_RATIO && directRttMs - relayRttMs >= AUTO_EMERGENCY_DELTA_MS;
    if (!severe2 && msSinceLastSwitch < AUTO_SWITCH_COOLDOWN_MS) return false;
    return directRttMs - relayRttMs >= autoRelaySwitchMarginMs(relayRttMs);
  }
  const severe = relayRttMs >= directRttMs * AUTO_EMERGENCY_RATIO && relayRttMs - directRttMs >= AUTO_EMERGENCY_DELTA_MS;
  if (!severe && msSinceLastSwitch < AUTO_SWITCH_COOLDOWN_MS) return true;
  return !(directRttMs <= relayRttMs + AUTO_DIRECT_RECOVER_DELTA_MS);
}
function isPathPreference(value) {
  return value === "auto" || value === "direct" || value === "relay";
}
var sameAddress = (a, b) => a !== null && b !== null && a.address === b.address && a.port === b.port;
function isRelayVia(value) {
  return value === "udp" || value === "websocket";
}
var PathRouter = class {
  constructor(port, reprobeMs, now2 = () => performance.now()) {
    __publicField(this, "port", port);
    __publicField(this, "reprobeMs", reprobeMs);
    __publicField(this, "now", now2);
    __publicField(this, "candidates", []);
    /** 下一轮从第几个候选地址验起。 */
    __publicField(this, "nextCandidate", 0);
    __publicField(this, "lastDirectAddress", null);
    __publicField(this, "lastObservedPath", null);
    __publicField(this, "measuredDirectRttMs", null);
    __publicField(this, "measuredDirectAt", 0);
    __publicField(this, "measuredRelayRttMs", null);
    __publicField(this, "measuredRelayAt", 0);
    __publicField(this, "localPreference", "auto");
    __publicField(this, "peerPreference", "auto");
    __publicField(this, "autoPreferRelay", false);
    __publicField(this, "peerAutoPreferRelay", false);
    __publicField(this, "lastAutoSwitchAt", Number.NEGATIVE_INFINITY);
    /** What this side last told the peer about its relay leg, and what the peer last told this side about its own. */
    __publicField(this, "announcedRelayVia", null);
    __publicField(this, "peerRelayVia", null);
    __publicField(this, "reprobe", null);
    __publicField(this, "standbyMeasure", null);
    __publicField(this, "initialStandbyTimer", null);
  }
  /** 还在走中转时每隔一阵再验证一轮，并定期轻测备用路径往返。连接关闭时调 `stop`。 */
  start() {
    this.reprobe = setInterval(() => {
      this.announceRelayVia();
      if (this.localPreference === "auto") this.evaluateAutoRoute(true);
      if (this.port.path() === "relay" && !this.effectivePreferRelay()) this.probeCandidates();
    }, this.reprobeMs);
    this.reprobe.unref?.();
    const standbyMs = this.reprobeMs * 3;
    this.initialStandbyTimer = setTimeout(() => {
      this.initialStandbyTimer = null;
      this.measureStandbyPath();
    }, Math.min(STANDBY_INITIAL_MEASURE_MS, standbyMs));
    this.initialStandbyTimer.unref?.();
    this.standbyMeasure = setInterval(() => this.measureStandbyPath(), standbyMs);
    this.standbyMeasure.unref?.();
  }
  stop() {
    if (this.reprobe) clearInterval(this.reprobe);
    this.reprobe = null;
    if (this.standbyMeasure) clearInterval(this.standbyMeasure);
    this.standbyMeasure = null;
    if (this.initialStandbyTimer) clearTimeout(this.initialStandbyTimer);
    this.initialStandbyTimer = null;
  }
  /** The peer's candidate addresses, already filtered and ordered (public first). */
  setCandidates(candidates) {
    this.candidates = candidates;
    this.nextCandidate = 0;
    if (this.port.path() !== "direct" && this.lastDirectAddress && !this.candidates.some((c) => sameAddress(c, this.lastDirectAddress))) {
      this.lastDirectAddress = null;
    }
    if (this.effectivePreferRelay()) this.measureStandbyPath();
    else this.probeCandidates();
  }
  /** A control-stream message: the peer's preference (`pathPreference`, `autoRelay`); other fields are not the router's. */
  onPeerPreference(message) {
    if (!isPathPreference(message.pathPreference) && typeof message.autoRelay !== "boolean") return;
    if (isPathPreference(message.pathPreference)) this.peerPreference = message.pathPreference;
    if (typeof message.autoRelay === "boolean") this.peerAutoPreferRelay = message.autoRelay;
    this.applyRoutePreference(true);
  }
  /** A control-stream message: how the peer's datagrams reach the relay now (`relayVia`); other fields are not this. */
  onPeerRelayVia(message) {
    if (isRelayVia(message.relayVia)) this.peerRelayVia = message.relayVia;
  }
  /**
   * Tells the peer how this side reaches the relay, when that changed since it was last told. The transport calls it once its
   * control stream is written (its first byte says what the stream is), then every reprobe round checks again.
   */
  announceRelayVia() {
    if (this.port.closed()) return;
    const via = this.port.localRelayVia?.() ?? null;
    if (via === null || via === this.announcedRelayVia) return;
    this.announcedRelayVia = via;
    this.port.writeControl(`${JSON.stringify({ relayVia: via })}
`);
  }
  announcePathPreference() {
    if (this.port.closed()) return;
    this.port.writeControl(`${JSON.stringify({ pathPreference: this.localPreference, autoRelay: this.autoPreferRelay })}
`);
  }
  effectivePreferRelay() {
    if (this.localPreference !== "auto") return this.localPreference === "relay";
    if (this.peerPreference !== "auto") return this.peerPreference === "relay";
    return this.autoPreferRelay || this.peerAutoPreferRelay;
  }
  freshRtt(value, at, now2) {
    return value !== null && now2 - at <= PATH_RTT_STALE_MS ? value : null;
  }
  pathMetrics() {
    const now2 = this.now();
    const active = this.port.path();
    const activeRtt = this.port.activeRttMs();
    const pathChanged = active !== null && active !== this.lastObservedPath;
    if (active !== null) this.lastObservedPath = active;
    if (active === "direct") {
      const addr = this.port.closed() ? null : this.port.directAddress();
      if (addr) this.lastDirectAddress = addr;
      if (activeRtt !== null) {
        this.measuredDirectRttMs = activeRtt;
        this.measuredDirectAt = now2;
      }
      const relayRttMs = this.freshRtt(this.measuredRelayRttMs, this.measuredRelayAt, now2);
      if (pathChanged && relayRttMs === null) this.measureStandbyPath();
      return {
        directRttMs: activeRtt ?? this.freshRtt(this.measuredDirectRttMs, this.measuredDirectAt, now2),
        relayRttMs,
        preference: this.localPreference,
        peerRelayVia: this.peerRelayVia
      };
    }
    if (active === "relay") {
      if (activeRtt !== null) {
        this.measuredRelayRttMs = activeRtt;
        this.measuredRelayAt = now2;
      }
      const directRttMs = this.freshRtt(this.measuredDirectRttMs, this.measuredDirectAt, now2);
      if (pathChanged && this.effectivePreferRelay() && directRttMs === null) this.measureStandbyPath();
      return {
        directRttMs,
        relayRttMs: activeRtt ?? this.freshRtt(this.measuredRelayRttMs, this.measuredRelayAt, now2),
        preference: this.localPreference,
        peerRelayVia: this.peerRelayVia
      };
    }
    return {
      directRttMs: this.freshRtt(this.measuredDirectRttMs, this.measuredDirectAt, now2),
      relayRttMs: this.freshRtt(this.measuredRelayRttMs, this.measuredRelayAt, now2),
      preference: this.localPreference,
      peerRelayVia: this.peerRelayVia
    };
  }
  setPathPreference(preference) {
    if (this.port.closed()) return;
    this.localPreference = preference;
    this.lastAutoSwitchAt = Number.NEGATIVE_INFINITY;
    if (preference !== "auto") {
      this.autoPreferRelay = false;
    } else {
      this.evaluateAutoRoute(false);
    }
    this.announcePathPreference();
    this.applyRoutePreference(true);
  }
  /** 本机换网或重建 UDP 套接字后：清掉旧网络的直连测速缓存与自动切路冷却，若此刻走中转则立即重新探测直连。 */
  onLocalNetworkChanged() {
    if (this.port.closed()) return;
    this.lastAutoSwitchAt = Number.NEGATIVE_INFINITY;
    this.measuredDirectRttMs = null;
    this.measuredDirectAt = 0;
    this.nextCandidate = 0;
    if (this.port.path() === "relay") {
      if (this.effectivePreferRelay()) this.measureStandbyPath();
      else this.probeCandidates();
    }
  }
  /** A `probe-rtt` sample: the round trip a validation measured on `address` (`relay`: it is this peer's relay path). */
  onProbeRtt(address, relay, rttUs) {
    if (this.port.closed()) return;
    const now2 = this.now();
    const rttMs = Math.max(0.1, rttUs / 1e3);
    if (relay) {
      this.measuredRelayRttMs = rttMs;
      this.measuredRelayAt = now2;
    } else {
      const direct = address;
      const existingFresh = this.freshRtt(this.measuredDirectRttMs, this.measuredDirectAt, now2);
      const keepExisting = this.lastDirectAddress !== null && !sameAddress(this.lastDirectAddress, direct) && existingFresh !== null && now2 - this.measuredDirectAt < this.reprobeMs && existingFresh < rttMs;
      if (!keepExisting) {
        this.lastDirectAddress = direct;
        this.measuredDirectRttMs = rttMs;
        this.measuredDirectAt = now2;
      }
    }
    const autoChanged = this.evaluateAutoRoute(true);
    if (!autoChanged && !relay && this.port.path() === "relay" && !this.effectivePreferRelay()) {
      this.port.probe(this.lastDirectAddress ?? address);
    }
  }
  evaluateAutoRoute(applyAndNotify) {
    if (this.localPreference !== "auto") return false;
    const { directRttMs, relayRttMs } = this.pathMetrics();
    const now2 = this.now();
    const next = decideAutoPreferRelay({
      currentPreferRelay: this.autoPreferRelay,
      directRttMs,
      relayRttMs,
      msSinceLastSwitch: now2 - this.lastAutoSwitchAt
    });
    if (next === this.autoPreferRelay) return false;
    this.autoPreferRelay = next;
    this.lastAutoSwitchAt = now2;
    if (applyAndNotify) {
      this.announcePathPreference();
      this.applyRoutePreference(true);
    }
    return true;
  }
  pickDirectTargets() {
    const now2 = this.now();
    if (this.lastDirectAddress && this.freshRtt(this.measuredDirectRttMs, this.measuredDirectAt, now2) === null) {
      this.lastDirectAddress = null;
    }
    const targets = [];
    if (this.lastDirectAddress) targets.push(this.lastDirectAddress);
    const total = this.candidates.length;
    if (total > 0 && targets.length < PROBES_PER_ROUND) {
      let checked = 0;
      while (checked < total && targets.length < PROBES_PER_ROUND) {
        const candidate = this.candidates[this.nextCandidate % total];
        this.nextCandidate = (this.nextCandidate + 1) % total;
        checked++;
        if (!targets.some((item) => sameAddress(item, candidate))) targets.push(candidate);
      }
    }
    return targets;
  }
  applyRoutePreference(triggerSwitch) {
    if (this.port.closed()) return;
    const preferRelay = this.effectivePreferRelay();
    this.port.setPreferRelay(preferRelay);
    if (!triggerSwitch) return;
    const current = this.port.path();
    if (preferRelay && current === "direct") {
      const relay = this.port.relayAddress();
      if (relay) this.port.probe(relay);
    } else if (!preferRelay && current === "relay") {
      for (const target of this.pickDirectTargets()) this.port.probe(target);
    }
  }
  measureStandbyPath() {
    if (this.port.closed()) return;
    const current = this.port.path();
    if (current === "direct") {
      const relay = this.port.relayAddress();
      if (relay) this.port.measure(relay);
    } else if (current === "relay" && this.effectivePreferRelay()) {
      for (const target of this.pickDirectTargets()) this.port.measure(target);
    }
  }
  probeCandidates() {
    if (this.port.closed()) return;
    const count = Math.min(PROBES_PER_ROUND, this.candidates.length);
    const measureFirst = this.localPreference === "auto" && this.port.path() === "relay" && this.port.relayAddress() !== null;
    for (let i = 0; i < count; i++) {
      const target = this.candidates[(this.nextCandidate + i) % this.candidates.length];
      if (measureFirst) this.port.measure(target);
      else this.port.probe(target);
    }
    this.nextCandidate = (this.nextCandidate + count) % Math.max(1, this.candidates.length);
  }
};

// .cache/shared-task-portable-91179cedad/packages/agent-net/src/nativeTransport.ts
function encodeNativeIo(header, parts = []) {
  const json = utf8(JSON.stringify(header));
  let size = 4 + json.length;
  for (const part of parts) size += part.length;
  const frame = new Uint8Array(size);
  new DataView(frame.buffer).setUint32(0, json.length, true);
  frame.set(json, 4);
  let offset = 4 + json.length;
  for (const part of parts) {
    frame.set(part, offset);
    offset += part.length;
  }
  return frame;
}
function decodeNativeIo(frame) {
  if (frame.length < 4) throw new Error("INVALID_NATIVE_IO");
  const length = new DataView(frame.buffer, frame.byteOffset, frame.byteLength).getUint32(0, true);
  if (4 + length > frame.length) throw new Error("INVALID_NATIVE_IO");
  const response = JSON.parse(decodeUtf8(frame.subarray(4, 4 + length)));
  if (!response.ok) throw new Error(response.code || "AGENT_NET_NATIVE_COMMAND_FAILED");
  return { value: response.value, payload: frame.subarray(4 + length) };
}
function readPoll(wire, payload) {
  let cursor = 0;
  const bytes = (item) => {
    if (!payload) return fromBase64Url(item.data ?? "");
    const length = item.len;
    if (typeof length !== "number" || !Number.isInteger(length) || length < 0 || cursor + length > payload.length) throw new Error("INVALID_NATIVE_IO");
    cursor += length;
    return payload.subarray(cursor - length, cursor);
  };
  const packets = wire.packets.map((packet) => ({ link: packet.link, data: bytes(packet) }));
  const connections = wire.connections.map((state) => ({ ...state, data: state.data.map((chunk) => ({ stream: chunk.stream, data: bytes(chunk) })) }));
  if (payload && cursor !== payload.length) throw new Error("INVALID_NATIVE_IO");
  return { ...wire, packets, connections };
}
var SUSPENSION_REASONS = /* @__PURE__ */ new Set(["data-silence", "request-timeouts", "unacked-sends"]);
var REBIND_REASONS = /* @__PURE__ */ new Set(["network-changed", "send-errors", "udp-blackhole"]);
function readRebindReason(value) {
  return typeof value === "string" && REBIND_REASONS.has(value) ? value : null;
}
function readRoute(value) {
  if (!value || typeof value !== "object") return null;
  const route = value;
  const rttMs = typeof route.rttMs === "number" && Number.isFinite(route.rttMs) && route.rttMs >= 0 ? route.rttMs : null;
  const suspension = route.udpSuspension;
  const udpSuspension = suspension && SUSPENSION_REASONS.has(suspension.reason) && typeof suspension.cooldownMs === "number" ? { reason: suspension.reason, cooldownMs: suspension.cooldownMs } : void 0;
  return route.via === "udp" ? { via: "udp", rttMs } : { via: "websocket", rttMs: null, ...udpSuspension ? { udpSuspension } : {} };
}
var MAX_PENDING = 16 * 1024 * 1024;
var MAX_CANDIDATES = 16;
var NATIVE_REPROBE_MS = 1e4;
var MAX_STUN_SERVERS = 4;
var UDP_SERVER_REFRESH_MS = 5 * 6e4;
var DATA = 68;
var CONTROL = 67;
var LANE_BY_KIND = new Map(Object.entries(SESSION_LANE_KINDS).map(([lane, kind]) => [kind, lane]));
var MAX_NATIVE_BODIES = 32;
var WRITES_PER_STREAM = 8;
var WRITE_CHUNK = 65536;
var FAST_POLL_MS = 8;
var IDLE_POLL_MS = 50;
var ACTIVE_WINDOW_MS = 1e3;
var IDLE_WAIT_MS = 250;
var IDLE_FULL_POLL_MS = 1e3;
var ADMISSION_RECHECK_MS = 1e3;
var MAX_IO_BYTES = 1024 * 1024;
var MAX_IO_WRITES = 512;
var MAX_RELAYED = 512;
var RELAY_UDP_DIAL_WAIT_MS = 200;
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
    /** `native-wait`: the engine wakes JS; no timers. Turned off if a wait ever fails (the timers take over). */
    __publicField(this, "waits", false);
    /** `binary-io`: writes, relayed datagrams and polls go through `io` (`exchange`). */
    __publicField(this, "binary");
    /**
     * Session v2 body streams (opened here, read from peers): only on an engine whose core sends every stream's credit when answering
     * a probe (`probe-grants`). An older core sends the two lowest streams' only, and a body is a connection's sixth stream: when its
     * first credit did not get through, the peer stops at 128 segments for good (2026-11-22, CI). Such a phone keeps to v1.
     */
    __publicField(this, "bodies");
    /** `binary-io` with `native-wait`: a waiting `io` call is out (`restBinary`); it reads for JS, a drive meanwhile does not. */
    __publicField(this, "resting", false);
    /** Polls a waiting `io` call brought back while a drive ran: the drive applies them before anything it reads itself. */
    __publicField(this, "parked", []);
    /** `binary-io`: datagrams from the relay WebSocket for the next `io` call. */
    __publicField(this, "relayed", []);
    /** `binary-io`: the next drive reads even with nothing to write (the first one, a dial's deadline, the periodic full poll). */
    __publicField(this, "mustRead", true);
    /** A poll is running; `again`: something happened meanwhile, so one more follows it. */
    __publicField(this, "polling", false);
    __publicField(this, "again", false);
    /** The wait whose return decides the next step; a later one supersedes it. */
    __publicField(this, "waitRound", 0);
    __publicField(this, "polledAt", 0);
    /** When a wake last polled at once (see `wake`). */
    __publicField(this, "wokeAt", Number.NEGATIVE_INFINITY);
    /** The socket's admission revision the engine last got, and when the admitted peers were last worked out. */
    __publicField(this, "mirroredVersion");
    __publicField(this, "admissionAt", Number.NEGATIVE_INFINITY);
    __publicField(this, "channels", /* @__PURE__ */ new Map());
    __publicField(this, "waiting", /* @__PURE__ */ new Map());
    __publicField(this, "remoteKeys", /* @__PURE__ */ new Map());
    __publicField(this, "links", /* @__PURE__ */ new Map());
    __publicField(this, "deviceForLink", /* @__PURE__ */ new Map());
    __publicField(this, "lastAdmission", "");
    __publicField(this, "nextLink", 0);
    __publicField(this, "pendingBytes", 0);
    __publicField(this, "features");
    __publicField(this, "localAddresses");
    __publicField(this, "mapped", []);
    __publicField(this, "stunObservations", null);
    __publicField(this, "portMapped", null);
    __publicField(this, "portMapper", null);
    __publicField(this, "lastLoggedDiagnostics", "");
    __publicField(this, "candidateList", []);
    /** The relay UDP credentials last given to the engine (`undefined`: none given yet). */
    __publicField(this, "relayCredentials");
    /** The relay UDP server the engine was last given with them: a new address (moved, or Fake-IP avoided) goes to it as well. */
    __publicField(this, "relaySyncedServer");
    __publicField(this, "relayUdpUp", false);
    /**
     * The credentials `relayUdpUp` is about and when they were first seen here, and the dials waiting for their path
     * (RELAY_UDP_DIAL_WAIT_MS). New credentials (the relay reconnected) start over: the path of the previous ones being up
     * says nothing about theirs.
     */
    __publicField(this, "relayUdpFor", null);
    __publicField(this, "relayUdpSince", now());
    __publicField(this, "relayUdpWaiters", []);
    __publicField(this, "relayUdpServer");
    /** The relay UDP server as configured (`host:port`), which `resolveUdpServer` turns into `relayUdpServer`. */
    __publicField(this, "relayUdpName");
    __publicField(this, "stunServers");
    __publicField(this, "stunGeneration", 0);
    __publicField(this, "udpRefresh", null);
    /** `relay-udp-health`: the route the engine last reported for relayed datagrams (`relayRoute`). */
    __publicField(this, "route", null);
    /** `udp-rebind`: last rebind generation observed from `poll` so each rebind notifies discovery/logs once. */
    __publicField(this, "lastRebindGen", 0);
    __publicField(this, "refreshingAddresses", false);
    this.id = keyHex(identity.transportKey);
    this.dial = identity.udpPort ? { udp: { address: "0.0.0.0", port: identity.udpPort } } : {};
    this.features = new Set(Array.isArray(identity.features) ? identity.features : []);
    this.waits = enhanced && this.features.has("native-wait") && typeof engine.wait === "function";
    this.binary = enhanced && this.features.has("binary-io") && typeof engine.io === "function";
    this.bodies = enhanced && this.features.has("probe-grants");
    this.relayUdpServer = options.resolveUdpServer ? void 0 : options.relayUdpServer;
    this.relayUdpName = options.relayUdpServer;
    this.stunServers = (options.stunServers ?? []).slice(0, MAX_STUN_SERVERS);
    this.localAddresses = addresses;
    if (enhanced && identity.udpPort && !options.publicCandidatesOnly && options.createPortMap) {
      this.portMapper = options.createPortMap((mapping) => {
        if (this.closed) return;
        this.portMapped = mapping;
        this.updateCandidates();
      });
    }
    this.candidateList = this.computeCandidates();
    options.relay?.uplink.onDatagram((deviceId, bytes) => {
      if (this.closed) return;
      const link = this.links.get(deviceId);
      if (!link) return;
      if (this.binary) {
        if (this.relayed.length >= MAX_RELAYED) this.relayed.shift();
        this.relayed.push({ link, bytes });
      } else void this.call({ op: "datagram", from: { link }, data: toBase64Url(bytes) }).catch(() => void 0);
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
      if (options.resolveUdpServer) void transport.resolveUdpServers();
      else await transport.startStun(transport.stunServers);
      if (identity.udpPort) transport.portMapper?.refresh(identity.udpPort);
      if (transport.waits) transport.drive();
      else transport.schedule();
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
  /** Benchmarks and tests that force the relay path: no private address is offered or probed (`publicCandidatesOnly`). */
  get publicOnly() {
    return this.options.publicCandidatesOnly === true;
  }
  /** The engine's relay link to the peer with this transport key, when it has a relay id. */
  linkOf(remoteId) {
    const deviceId = this.options.relayIdOf?.(remoteId);
    return deviceId && this.links.get(deviceId) || null;
  }
  computeCandidates() {
    const port = this.identity.udpPort;
    if (!port) return [];
    const allowed = (address) => address.length <= 128 && (!this.options.publicCandidatesOnly || !isPrivate(address));
    const local = this.localAddresses.filter(allowed).map((address) => ({ address, port }));
    if (!this.enhanced) return local.slice(0, MAX_CANDIDATES);
    const seen = /* @__PURE__ */ new Set();
    const portMapped = this.portMapped && allowed(this.portMapped.address) ? [{ address: this.portMapped.address, port: this.portMapped.port }] : [];
    return [...local, ...this.mapped.filter((candidate) => allowed(candidate.address)), ...portMapped].filter((candidate) => {
      const key3 = `${candidate.address}:${candidate.port}`;
      if (seen.has(key3)) return false;
      seen.add(key3);
      return true;
    }).sort((a, b) => Number(isPrivate(a.address)) - Number(isPrivate(b.address))).slice(0, MAX_CANDIDATES);
  }
  diagnostics() {
    const observations = this.stunObservations ?? this.mapped;
    const { natMapping, portPreserving } = classifyNatMapping(observations, this.identity.udpPort);
    let localCandidates = 0;
    let publicCandidates = 0;
    for (const candidate of this.candidateList) {
      if (isPrivate(candidate.address)) localCandidates += 1;
      else publicCandidates += 1;
    }
    return {
      natMapping,
      portPreserving,
      stunResponses: observations.length,
      portMapped: this.portMapped?.protocol ?? null,
      localCandidates,
      publicCandidates
    };
  }
  maybeLogDiagnostics() {
    const hasStun = (this.stunObservations ?? this.mapped).length > 0;
    if (!this.options.onLog || !hasStun && !this.portMapped) return;
    const snapshot = this.diagnostics();
    const line = formatTransportDiagnosticsLog(snapshot);
    if (line === this.lastLoggedDiagnostics) return;
    this.lastLoggedDiagnostics = line;
    const level = snapshot.natMapping === "symmetric" || snapshot.natMapping === "multi-egress" ? "warn" : "info";
    this.options.onLog(level, line);
  }
  updateCandidates() {
    const next = this.computeCandidates();
    if (JSON.stringify(next) !== JSON.stringify(this.candidateList)) {
      this.candidateList = next;
      for (const channel of this.channels.values()) channel.announceCandidates();
    }
    this.maybeLogDiagnostics();
  }
  async configureUdpServer(server2, extraStunServers = []) {
    if (this.closed || !this.enhanced) return;
    this.relayUdpName = server2;
    this.relayUdpServer = await this.resolveUdpServer(server2);
    if (this.closed) return;
    this.wake();
    await this.configureStunServers([this.relayUdpServer, ...extraStunServers]);
  }
  async configureStunServers(servers) {
    if (this.closed || !this.enhanced) return;
    const unique = [...new Set(servers.map((s) => s.trim()).filter(Boolean))].slice(0, MAX_STUN_SERVERS);
    if (!unique.length) return;
    const generation = ++this.stunGeneration;
    const resolved = this.options.resolveUdpServer ? await Promise.all(unique.map((server2) => this.resolveUdpServer(server2))) : unique;
    if (this.closed || generation !== this.stunGeneration) return;
    this.stunServers = [...new Set(resolved)].slice(0, MAX_STUN_SERVERS);
    await this.startStun(this.stunServers);
  }
  /** The relay UDP and STUN servers as `resolveUdpServer` gives them (unchanged without it, or when it fails). */
  async resolveUdpServers() {
    if (!this.options.resolveUdpServer) return;
    const generation = this.stunGeneration;
    const [relay, stun] = await Promise.all([
      this.relayUdpName ? this.resolveUdpServer(this.relayUdpName) : void 0,
      Promise.all(this.stunServers.map((server2) => this.resolveUdpServer(server2)))
    ]);
    if (this.closed) return;
    this.relayUdpServer ?? (this.relayUdpServer = relay);
    this.wake();
    if (generation === this.stunGeneration) {
      this.stunServers = stun;
      await this.startStun(this.stunServers);
    }
    if (!this.udpRefresh && this.relayUdpName && !this.closed) {
      this.udpRefresh = setInterval(() => {
        void this.refreshUdpServer();
      }, UDP_SERVER_REFRESH_MS);
      this.udpRefresh.unref?.();
    }
  }
  resolveUdpServer(server2) {
    const resolve = this.options.resolveUdpServer;
    return resolve ? resolve(server2).catch(() => server2) : Promise.resolve(server2);
  }
  /** The relay's UDP host answers with another address now (moved, or a proxy's Fake-IP went away): the engine registers there. */
  async refreshUdpServer() {
    if (this.closed || !this.relayUdpName || !this.options.resolveUdpServer) return;
    const next = await this.resolveUdpServer(this.relayUdpName);
    if (this.closed || next === this.relayUdpServer) return;
    const previous = this.relayUdpServer;
    this.relayUdpServer = next;
    this.wake();
    const stun = [next, ...this.stunServers.filter((server2) => server2 !== previous && server2 !== next)].slice(0, MAX_STUN_SERVERS);
    this.stunServers = stun;
    await this.startStun(stun);
  }
  async startStun(servers = this.stunServers) {
    if (!servers.length || !this.identity.udpPort || !this.supports("stun")) return;
    await this.call({ op: "stun", servers }).catch(() => void 0);
  }
  /**
   * The relay's UDP path follows the relay WebSocket's session: new credentials on every reconnect, none when it offered
   * none (an older relay, plain http). Until the relay acknowledges a registration, datagrams stay on the WebSocket.
   */
  async synchronizeRelayUdp() {
    const server2 = this.relayUdpServer, read = this.options.relay?.udpCredentials;
    if (!server2 || !read || !this.identity.udpPort || !this.supports("relay-udp-v2")) return;
    const credentials = read() ?? null;
    this.noteRelayCredentials(credentials);
    if (credentials === this.relayCredentials && server2 === this.relaySyncedServer) return;
    this.relayCredentials = credentials;
    this.relaySyncedServer = server2;
    await this.call({ op: "relayUdp", server: server2, ...credentials ? { session: toBase64Url(credentials.session), key: toBase64Url(credentials.key), ...credentials.probe === true ? { probe: true } : {} } : { session: null } });
  }
  noteRelayCredentials(credentials) {
    if (credentials === this.relayUdpFor) return;
    this.relayUdpFor = credentials;
    this.relayUdpUp = false;
    this.relayUdpSince = now();
  }
  /** See RELAY_UDP_DIAL_WAIT_MS. Resolves at once when the path is up, cannot come up, or has had its time. */
  relayUdpSettled() {
    const credentials = this.options.relay?.udpCredentials?.() ?? null;
    if (!credentials || this.closed || !this.enhanced || !this.identity.udpPort || !this.supports("relay-udp-v2")) return Promise.resolve();
    this.noteRelayCredentials(credentials);
    const remaining = this.relayUdpSince + RELAY_UDP_DIAL_WAIT_MS - now();
    if (this.relayUdpUp || remaining <= 0) return Promise.resolve();
    return new Promise((resolve) => {
      const done = () => {
        clearTimeout(timer);
        this.relayUdpWaiters = this.relayUdpWaiters.filter((waiter) => waiter !== done);
        resolve();
      };
      const timer = setTimeout(done, remaining);
      this.relayUdpWaiters.push(done);
      this.wake();
    });
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
    const version = this.options.admissionVersion?.();
    const entries = this.options.admittedPeers().map((peer) => {
      if (!/^[a-f0-9]{64}$/.test(peer.id) || !this.options.admit(peer.id)) throw new Error("INVALID_NATIVE_PEER");
      const key3 = Uint8Array.from(peer.id.match(/../g), (part) => parseInt(part, 16));
      return { key: toBase64Url(key3), link: this.linkFor(peer.relayId), ...this.enhanced ? { relayId: peer.relayId } : {} };
    }).sort((a, b) => a.link - b.link);
    const serialized = JSON.stringify(entries);
    if (serialized !== this.lastAdmission) {
      await this.call({ op: "admit", peers: entries });
      this.lastAdmission = serialized;
    }
    this.admissionAt = now();
    this.mirroredVersion = version;
  }
  async connect(entry) {
    if (!this.options.admit(entry.id)) throw new Error("UNAUTHORIZED_PEER");
    await this.synchronizeAdmission();
    const dial = entry.dial;
    const expected = this.options.relayIdOf?.(entry.id);
    if (!expected || dial.relayId !== expected) throw new Error("PEER_ADDRESS_MISMATCH");
    const address = dial.preferUdp && dial.udp ? dial.udp : { link: this.linkFor(expected) };
    if ("link" in address) await this.relayUdpSettled();
    const key3 = toBase64Url(Uint8Array.from(entry.id.match(/../g), (part) => parseInt(part, 16)));
    const id = await this.call({ op: "connect", key: key3, address });
    const budgetMs = typeof dial.timeoutMs === "number" && dial.timeoutMs > 0 ? dial.timeoutMs : 3e3;
    return new Promise((resolve, reject) => {
      if (this.closed) {
        reject(new Error("NATIVE_TRANSPORT_CLOSED"));
        return;
      }
      this.waiting.set(id, { resolve, reject, deadline: now() + budgetMs });
      this.wake();
    });
  }
  /**
   * How relayed datagrams go now (types.ts `RelayRoute`), as the WASM transport reports it (transport.ts `relayRoute`): over the
   * relay's UDP port with its registration round trip, or over the relay WebSocket, and why while relay UDP is off for carrying
   * no data. Null without a relay. An engine without `relay-udp-health` reports only whether UDP is up, without a round trip.
   */
  relayRoute() {
    if (!this.options.relay || this.closed) return null;
    if (this.relayUdpUp) return { via: "udp", rttMs: this.route?.via === "udp" ? this.route.rttMs : null };
    const suspension = this.route?.udpSuspension;
    return suspension ? { via: "websocket", rttMs: null, udpSuspension: suspension } : { via: "websocket", rttMs: null };
  }
  /** Session requests to a relayed peer timed out: the engine judges whether relay UDP carries data (udp_paths.rs `note_stall`). */
  relayStalled() {
    if (this.closed || !this.supports("relay-udp-health")) return;
    void this.call({ op: "relayStalled" }).catch(() => void 0);
    this.wake();
  }
  /**
   * The phone changed networks: connections send from the new address now (the peer follows), STUN asks again, and the
   * local addresses are read again for the candidates.
   */
  networkChanged() {
    if (this.closed || !this.enhanced) return;
    void this.call({ op: "migrate" }).catch(() => void 0);
    for (const channel of this.channels.values()) channel.onLocalNetworkChanged();
    this.wake();
    void this.refreshUdpServer();
    if (this.identity.udpPort) this.portMapper?.refresh(this.identity.udpPort);
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
    if (this.closed || this.timer || this.polling) return;
    this.timerDelay = delay;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.drive();
    }, delay);
  }
  /**
   * Something to move: poll now. React Native runs timers on the display's frames, so a zero timer was up to a frame late
   * (7–20 ms measured, 2026-11-21) and a request sat in JS that long before the engine saw it. On timers (binaries without
   * `native-wait`), a wake within FAST_POLL_MS of the previous one keeps that rhythm instead, so a run of writes does not
   * poll per write.
   */
  wake() {
    this.activeUntil = now() + ACTIVE_WINDOW_MS;
    if (this.closed) return;
    if (!this.waits && !this.polling && now() - this.wokeAt < FAST_POLL_MS) {
      if (this.timer && this.timerDelay > FAST_POLL_MS) {
        clearTimeout(this.timer);
        this.timer = null;
      }
      this.schedule(FAST_POLL_MS);
      return;
    }
    this.wokeAt = now();
    this.drive();
  }
  /** The roster or the peer rule changed: mirror it into the engine now rather than at the next poll. */
  admissionChanged() {
    this.wake();
  }
  /**
   * Poll now. During a poll a wake is noted and one more poll follows it; after that the engine is left waiting (`rest`), or on
   * timers the next poll is scheduled.
   */
  drive(read = false) {
    if (read) this.mustRead = true;
    if (this.closed) return;
    if (this.polling) {
      this.again = true;
      return;
    }
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    this.polling = true;
    void (async () => {
      try {
        if (this.binary) {
          await this.exchange();
          if (this.again && !this.closed) {
            this.again = false;
            await this.exchange();
          }
        } else {
          await this.writeFirst();
          await this.poll();
          if (this.again && !this.closed) {
            this.again = false;
            await this.writeFirst();
            await this.poll();
          }
        }
      } catch {
        this.polling = false;
        await this.close();
        return;
      }
      this.polling = false;
      this.again = false;
      if (this.closed) return;
      if (this.parked.length) {
        this.drive();
        return;
      }
      if (!this.waits) this.schedule();
      else if (!this.binary) this.rest();
      else if (!this.resting) this.restBinary();
      else if (this.busy()) this.kickRest();
    })();
  }
  busy() {
    return this.waiting.size > 0 || [...this.channels.values()].some((channel) => channel.moving);
  }
  async io(input, waitMs, kick) {
    if (this.closed) throw new Error("NATIVE_TRANSPORT_CLOSED");
    this.engine.assertCurrent?.();
    const output = await this.engine.io(input, waitMs, kick);
    this.engine.assertCurrent?.();
    if (this.closed) throw new Error("NATIVE_TRANSPORT_CLOSED");
    return output instanceof Uint8Array ? output : new Uint8Array(output);
  }
  /**
   * `binary-io`: one turn. What a waiting call read meanwhile goes first; then the admitted peers and the relay's credentials
   * go to the engine if they changed (before any write, as in `writeFirst`); then one `io` call hands the engine this turn's
   * relayed datagrams and writes and reads, unless a waiting call is out: that call reads, and this one wakes it if the engine
   * has something for JS afterwards (a datagram for the relay WebSocket, an answer).
   */
  async exchange() {
    await this.applyParked();
    if (this.closed) return;
    const version = this.options.admissionVersion?.();
    const changed = version === void 0 || version !== this.mirroredVersion;
    if (changed) await this.synchronizeAdmission();
    await this.synchronizeRelayUdp();
    const datagrams = [], parts = [];
    for (let bytes = 0; this.relayed.length && bytes + this.relayed[0].bytes.length <= MAX_IO_BYTES; ) {
      const { link, bytes: data } = this.relayed.shift();
      datagrams.push([link, data.length]);
      parts.push(data);
      bytes += data.length;
    }
    const writes = [], planned = [], budget = { bytes: MAX_IO_BYTES, writes: MAX_IO_WRITES };
    for (const channel of [...this.channels.values()]) {
      if (!channel.moving || !this.options.admit(channel.remoteId)) continue;
      planned.push(channel);
      try {
        writes.push(...await channel.plan(budget));
      } catch {
        channel.close({ drain: false });
        this.engine.assertCurrent?.();
      }
    }
    for (const write of writes) parts.push(write.bytes);
    const read = !this.resting && (!this.waits || this.mustRead || parts.length > 0 || this.waiting.size > 0);
    if (read || parts.length) {
      if (read) {
        this.mustRead = false;
        this.polledAt = now();
      }
      const waitingAtPoll = new Map(this.waiting);
      const header = { datagrams, writes: writes.map((write) => [write.channel.connectionId, write.outgoing.stream, write.bytes.length]), poll: read };
      const { value, payload } = decodeNativeIo(await this.io(encodeNativeIo(header, parts), 0, this.resting));
      if (!Array.isArray(value.written) || value.written.length !== writes.length) throw new Error("INVALID_NATIVE_IO");
      writes.forEach((write, index) => write.channel.consume(write.outgoing, value.written[index], write.bytes.length));
      await this.applyParked();
      if (value.poll) await this.applyPoll(readPoll(value.poll, payload), waitingAtPoll, false);
    }
    for (const channel of planned) await channel.afterWrites();
    if (!changed && now() - this.admissionAt >= ADMISSION_RECHECK_MS) await this.synchronizeAdmission();
  }
  async applyParked() {
    while (this.parked.length && !this.closed) {
      const { poll, waitingAtPoll } = this.parked.shift();
      await this.applyPoll(poll, waitingAtPoll, false);
    }
  }
  /**
   * `binary-io` with `native-wait`: one `io` call waits in the engine until it has something for JS and brings it back in
   * the same call. Writes meanwhile go in their own `io` calls that do not read (`exchange`), so only one call reads at a
   * time and what is read reaches JS in order.
   */
  restBinary() {
    if (this.closed || this.resting) return;
    this.resting = true;
    const waitingAtPoll = new Map(this.waiting);
    void this.io(encodeNativeIo({ poll: true }), this.busy() ? FAST_POLL_MS : IDLE_WAIT_MS, false).then((output) => {
      this.resting = false;
      if (this.closed) return;
      if (output.length) {
        const { value, payload } = decodeNativeIo(output);
        if (value.poll) {
          this.polledAt = now();
          this.parked.push({ poll: readPoll(value.poll, payload), waitingAtPoll });
        }
      }
      if (this.polling) {
        this.again = true;
        return;
      }
      if (this.parked.length) this.drive();
      else if (this.busy() || this.mirrorChanged() || now() - this.polledAt >= IDLE_FULL_POLL_MS) this.drive(true);
      else this.restBinary();
    }).catch(() => {
      this.resting = false;
      if (!this.closed) void this.close();
    });
  }
  kickRest() {
    if (this.engine.kick) {
      try {
        this.engine.kick();
        return;
      } catch {
      }
    }
    if (!this.timer) this.timer = setTimeout(() => {
      this.timer = null;
      this.drive(true);
    }, FAST_POLL_MS);
  }
  /**
   * Bytes waiting here go to the engine before the poll, not after it. The engine sends on the write itself; a poll is a
   * bridge round trip and then a pass over every connection, and a request used to wait for both before it was written:
   * with seven computers connected, about 10 ms on a phone whose cores had clocked down (2026-11-21, 2.6 ms for the round
   * trip and 6 ms for the pass), on a line whose round trip was 4 ms. Only while the socket has not reported a change to
   * what JS mirrors into the engine, and only to a peer admitted right now (`admit` reads the clock): after a change the
   * poll hands the engine the admitted peers first, as it always did. The once-a-second look for admission that lapsed
   * with time (ADMISSION_RECHECK_MS) does not hold a write back: it took 8–17 ms with 26 devices in the account, and a
   * request that came when it was due waited for all of it.
   */
  async writeFirst() {
    if (this.options.admissionVersion?.() === void 0 || this.mirrorChanged()) return;
    for (const channel of [...this.channels.values()]) {
      if (!channel.moving || !this.options.admit(channel.remoteId)) continue;
      try {
        await channel.flush();
      } catch {
        channel.close({ drain: false });
        this.engine.assertCurrent?.();
      }
    }
  }
  /**
   * `native-wait`: leave the engine to itself until it has something for JS. With bytes still to hand to it (or a dial, a
   * close draining) JS comes back after FAST_POLL_MS at the latest, as the timers did; otherwise after IDLE_WAIT_MS, and
   * then polls only if something it mirrors changed or the last poll is IDLE_FULL_POLL_MS old.
   */
  rest() {
    if (this.closed) return;
    const round = ++this.waitRound;
    const busy = this.waiting.size > 0 || [...this.channels.values()].some((channel) => channel.moving);
    void this.engine.wait(busy ? FAST_POLL_MS : IDLE_WAIT_MS).then((work) => {
      if (this.closed) return;
      if (work) {
        this.drive();
        return;
      }
      if (round !== this.waitRound) return;
      if (busy || this.mirrorChanged() || now() - this.polledAt >= IDLE_FULL_POLL_MS) this.drive();
      else this.rest();
    }, () => {
      if (this.closed || !this.waits) return;
      this.waits = false;
      this.schedule(0);
    });
  }
  /** A connection's remote key in hex. It never changes for a connection, and every poll reports every connection. */
  remoteKey(state) {
    const known = this.remoteKeys.get(state.id);
    if (known?.raw === state.remoteKey) return known.hex;
    const hex = keyHex(state.remoteKey);
    this.remoteKeys.set(state.id, { raw: state.remoteKey, hex });
    return hex;
  }
  mirrorChanged() {
    return this.options.admissionVersion?.() !== this.mirroredVersion || (this.options.relay?.udpCredentials?.() ?? null) !== (this.relayCredentials ?? null) || this.relayUdpServer !== void 0 && this.relayUdpServer !== this.relaySyncedServer;
  }
  async poll() {
    this.polledAt = now();
    const version = this.options.admissionVersion?.();
    if (version === void 0 || version !== this.mirroredVersion || this.polledAt - this.admissionAt >= ADMISSION_RECHECK_MS) {
      await this.synchronizeAdmission();
    }
    await this.synchronizeRelayUdp();
    const waitingAtPoll = new Map(this.waiting);
    await this.applyPoll(readPoll(await this.call({ op: "poll" }), null), waitingAtPoll, true);
  }
  /**
   * What a poll read, applied in the order the engine read it. `flush`: hand each connection's queued bytes to the engine as
   * it goes (the command path); `binary-io` writes them in the next `io` call instead.
   */
  async applyPoll(result, waitingAtPoll, flush) {
    for (const packet of result.packets) {
      const deviceId = this.deviceForLink.get(packet.link);
      if (deviceId) this.options.relay?.uplink.send(deviceId, packet.data);
    }
    this.relayUdpUp = result.relayUdp === true && this.relayUdpFor === this.relayCredentials;
    if (this.relayUdpUp) for (const done of [...this.relayUdpWaiters]) done();
    if (result.relayRoute !== void 0) this.route = readRoute(result.relayRoute);
    const traffic = this.options.udpTraffic;
    if (traffic && Array.isArray(result.udpTraffic) && result.udpTraffic.every((value) => Number.isSafeInteger(value) && value >= 0)) {
      Atomics.store(traffic, 0, BigInt(result.udpTraffic[0]));
      Atomics.store(traffic, 1, BigInt(result.udpTraffic[1]));
    }
    const rebind = result.udpRebind;
    if (rebind && Number.isInteger(rebind.gen) && rebind.gen > this.lastRebindGen && Number.isInteger(rebind.port) && rebind.port > 0 && rebind.port <= 65535) {
      const reason = readRebindReason(rebind.reason);
      if (reason) {
        this.lastRebindGen = rebind.gen;
        this.identity.udpPort = rebind.port;
        this.dial.udp = { address: "0.0.0.0", port: rebind.port };
        this.mapped = [];
        this.updateCandidates();
        for (const channel of this.channels.values()) channel.onLocalNetworkChanged();
        this.options.onLocalPortChanged?.(rebind.port, reason);
      }
    } else if (typeof result.udpPort === "number" && Number.isInteger(result.udpPort) && result.udpPort > 0 && result.udpPort <= 65535 && result.udpPort !== this.identity.udpPort) {
      this.identity.udpPort = result.udpPort;
      this.dial.udp = { address: "0.0.0.0", port: result.udpPort };
      this.updateCandidates();
    }
    const readAddresses = (raw) => raw.filter((value) => value && typeof value.address === "string" && value.address.length <= 128 && Number.isInteger(value.port) && value.port > 0 && value.port <= 65535).slice(0, MAX_STUN_SERVERS);
    let diagnosticsChanged = false;
    if (Array.isArray(result.stunObservations)) {
      const observations = readAddresses(result.stunObservations);
      if (JSON.stringify(observations) !== JSON.stringify(this.stunObservations)) {
        this.stunObservations = observations;
        diagnosticsChanged = true;
      }
    }
    if (Array.isArray(result.mapped)) {
      const mapped = readAddresses(result.mapped);
      if (JSON.stringify(mapped) !== JSON.stringify(this.mapped)) {
        this.mapped = mapped;
        this.updateCandidates();
        diagnosticsChanged = false;
      }
    }
    if (diagnosticsChanged) this.maybeLogDiagnostics();
    const alive = new Set(result.connections.map((connection) => connection.id));
    for (const id of this.remoteKeys.keys()) if (!alive.has(id)) this.remoteKeys.delete(id);
    for (const state of result.connections) {
      let channel = this.channels.get(state.id);
      const key3 = this.remoteKey(state);
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
          if (flush && channel.moving) await channel.flush();
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
    if (this.udpRefresh) clearInterval(this.udpRefresh);
    this.udpRefresh = null;
    await this.portMapper?.close().catch(() => void 0);
    const ids = [...this.channels.keys(), ...this.waiting.keys()];
    for (const pending of this.waiting.values()) pending.reject(new Error("NATIVE_TRANSPORT_CLOSED"));
    this.waiting.clear();
    this.parked = [];
    this.relayed = [];
    for (const done of [...this.relayUdpWaiters]) done();
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
    /**
     * `binary-io`: the stream took less than it was given last time (its send buffer is full). It gets one chunk per turn until
     * it takes a whole one, so a full stream does not carry half a megabyte across the bridge every turn only to refuse it.
     */
    __publicField(this, "short", false);
  }
  push(bytes) {
    this.items.push({ bytes, offset: 0 });
    this.queued += bytes.length;
  }
};
var Body = class extends Outgoing {
  constructor() {
    super(...arguments);
    __publicField(this, "closing", false);
    __publicField(this, "ended", false);
    __publicField(this, "abandoned", false);
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
    /** Session v2 body streams this side opened, until the core holds nothing of them. */
    __publicField(this, "bodies", []);
    /** `key`: a body stream's key, once its four bytes arrived after the kind (`head` collects them). */
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
    __publicField(this, "bodyHandler", null);
    __publicField(this, "earlyBodies", []);
    /** This side declared `AGENT_NET_SESSION_V2`: the peer may open body streams. */
    __publicField(this, "bodiesDeclared", false);
    __publicField(this, "drainHandlers", []);
    __publicField(this, "pathHandlers", []);
    __publicField(this, "reportedPath", "");
    /**
     * `path-routing` engines: direct or relayed, and when to probe or measure which path, the same as on the WASM transport
     * (pathRouter.ts), with the peer's preference synced on the control stream. Older engines probe the candidates every 10 s.
     */
    __publicField(this, "router");
    /** `bufferedAmount` when the turn's writes were planned, for `afterWrites`. */
    __publicField(this, "plannedFrom", 0);
    const fire = (command) => {
      void owner.call({ ...command, id }).catch(() => void 0);
    };
    this.router = owner.enhanced && owner.supports("path-routing") ? new PathRouter({
      closed: () => this.events.closed || this.disposed,
      path: () => this.path(),
      directAddress: () => this.directAddress(),
      activeRttMs: () => (this.state?.rttUs ?? 0) > 0 ? this.state.rttUs / 1e3 : null,
      relayAddress: () => {
        const link = owner.linkOf(remoteId);
        return link ? { link } : null;
      },
      probe: (address) => fire({ op: "probe", address }),
      measure: (address) => fire({ op: "measure", address }),
      setPreferRelay: (prefer) => fire({ op: "preferRelay", prefer }),
      writeControl: (line) => {
        this.control.push(utf8(line));
        owner.wake();
      },
      localRelayVia: () => owner.relayRoute()?.via ?? null
    }, NATIVE_REPROBE_MS) : null;
    this.router?.start();
  }
  async initialize() {
    this.data.stream = await this.owner.call({ op: "openStream", id: this.id });
    await this.owner.call({ op: "write", id: this.id, stream: this.data.stream, data: toBase64Url(Uint8Array.of(DATA)) });
    this.control.stream = await this.owner.call({ op: "openStream", id: this.id, priority: "interactive" });
    const bytes = concatBytes([Uint8Array.of(CONTROL), utf8(JSON.stringify({ candidates: this.owner.candidates() }) + "\n")]);
    await this.owner.call({ op: "write", id: this.id, stream: this.control.stream, data: toBase64Url(bytes) });
    this.router?.announceRelayVia();
  }
  /** This side's candidates changed (STUN answered, another network): tell the peer, as the Desktop re-announces. */
  announceCandidates() {
    if (this.events.closed || !this.owner.candidates().length) return;
    this.control.push(utf8(JSON.stringify({ candidates: this.owner.candidates() }) + "\n"));
    this.owner.wake();
  }
  /** Local network changed: drop stale direct RTT / auto-switch cooldown and re-probe direct if currently relayed. */
  onLocalNetworkChanged() {
    this.router?.onLocalNetworkChanged();
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
    return !this.disposed && (this.closeDeadline > 0 || this.data.queued > 0 || this.control.queued > 0 || this.lanes !== null && (this.lanes.control.queued > 0 || this.lanes.normal.queued > 0 || this.lanes.background.queued > 0) || this.bodies.some((body) => body.queued > 0 || body.closing && !body.ended));
  }
  /** Session v2: this channel opens and reads body streams (as the Desktop's CoreChannel); not on a plain-native transport. */
  get sessionBodies() {
    return this.owner.bodies;
  }
  onDrain(handler) {
    this.drainHandlers.push(handler);
  }
  /** See CoreChannel.declareSessions (transport.ts): once per connection, on the control stream older nodes read only for candidates. */
  declareSessions(features = []) {
    if (!this.owner.enhanced || this.sessionsDeclared || this.events.closed) return;
    this.sessionsDeclared = true;
    this.bodiesDeclared = features.includes(AGENT_NET_SESSION_V2);
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
    const lanes = this.lanes, channel = this;
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
        return lanes.control.queued + lanes.control.core + lanes.normal.queued + lanes.normal.core + lanes.background.queued + channel.bodiesBuffered();
      },
      onData: (handler) => {
        this.sessionHandler = handler;
        for (const [lane, bytes] of this.earlySession.splice(0)) handler(lane, bytes);
        this.earlySessionBytes = 0;
      },
      openBody: (lane, key3) => this.openBody(lane, key3),
      onBody: (handler) => {
        this.bodyHandler = handler;
        for (const [key3, bytes] of this.earlyBodies.splice(0)) handler(key3, bytes);
      },
      onDrain: (handler) => this.onDrain(handler)
    };
  }
  /** Session v2: bodies count like their lanes, on the control and normal lanes with what the core still buffers. */
  bodiesBuffered() {
    let total = 0;
    for (const body of this.bodies) total += body.queued + (body.priority === "background" ? 0 : body.core);
    return total;
  }
  /** Session v2: a stream of its own for one message body, at its lane's priority; opened in the engine with its first write. */
  openBody(lane, key3) {
    if (!this.owner.bodies || this.events.closed || this.bodies.length >= MAX_NATIVE_BODIES) return null;
    const body = new Body(SESSION_LANE_PRIORITY[lane], false);
    const head = new Uint8Array(SESSION_BODY_HEADER_BYTES);
    head[0] = SESSION_BODY_KIND;
    new DataView(head.buffer).setUint32(1, key3, false);
    body.push(head);
    this.bodies.push(body);
    this.owner.wake();
    return {
      write: (bytes) => {
        if (!this.events.closed && !body.closing) {
          body.push(bytes);
          this.owner.wake();
        }
      },
      finish: () => {
        if (!body.closing) {
          body.closing = true;
          this.owner.wake();
        }
      },
      abandon: () => this.abandonBody(body)
    };
  }
  /** What waits here is dropped, and what the engine's core has not sent (`abandon`): the peer sees the body end short. */
  abandonBody(body) {
    if (body.abandoned || this.disposed) return;
    body.abandoned = true;
    body.closing = true;
    body.items = [];
    body.queued = 0;
    if (!body.ended) {
      this.owner.wake();
      return;
    }
    if (body.stream !== null) {
      void this.owner.call({ op: "abandon", id: this.id, stream: body.stream }).catch(() => void 0);
    }
  }
  sessionBody(key3, bytes) {
    if (this.bodyHandler) {
      this.bodyHandler(key3, bytes);
      return;
    }
    this.earlySessionBytes += (bytes?.length ?? 0) + EARLY_BODY_EVENT_BYTES;
    if (this.earlySessionBytes > MAX_EARLY_SESSION_BYTES) {
      this.close({ drain: false });
      return;
    }
    this.earlyBodies.push([key3, bytes && bytes.slice()]);
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
  /** Control first, then the interactive lane, normal traffic, and the background lane last; each lane's bodies after it. */
  order() {
    if (!this.owner.enhanced) return [this.data];
    const bodies = (priority) => this.bodies.filter((body) => body.priority === priority && !body.ended);
    return [
      this.control,
      ...this.lanes ? [this.lanes.control] : [],
      ...bodies("interactive"),
      ...this.lanes ? [this.lanes.normal] : [],
      ...bodies("normal"),
      this.data,
      ...this.lanes ? [this.lanes.background] : [],
      ...bodies("background")
    ];
  }
  get connectionId() {
    return this.id;
  }
  /** Hands queued bytes to the engine in `order`. */
  async flush() {
    if (this.disposed) return;
    if (this.closeDeadline && now() >= this.closeDeadline) {
      this.dispose();
      return;
    }
    const before = this.bufferedAmount;
    for (const outgoing of this.order()) {
      if (this.disposed) return;
      if (outgoing.items.length) await this.flushStream(outgoing);
    }
    await this.drained(before);
  }
  async drained(before) {
    if (this.disposed) return;
    if (this.owner.enhanced && this.bufferedAmount < before) for (const handler of this.drainHandlers) handler();
    for (const body of [...this.bodies]) {
      if (!body.closing || body.ended || body.items.length || this.disposed) continue;
      body.ended = true;
      if (body.stream !== null) await this.owner.call({ op: body.abandoned ? "abandon" : "finish", id: this.id, stream: body.stream });
    }
    if (this.disposed) return;
    const order = this.order();
    if (this.closeDeadline && !this.finished && order.every((outgoing) => !outgoing.items.length)) {
      this.finished = true;
      for (const outgoing of order) if (outgoing.stream !== null) await this.owner.call({ op: "finish", id: this.id, stream: outgoing.stream });
    }
  }
  /**
   * `binary-io`: this turn's writes, in `order` and as `flushStream` would make them, at most `budget.bytes` and `budget.writes` in
   * all. Nothing is taken from the queues here: `consume` takes what the engine answers it took, and the rest goes next turn.
   */
  async plan(budget) {
    if (this.disposed) return [];
    if (this.closeDeadline && now() >= this.closeDeadline) {
      this.dispose();
      return [];
    }
    this.plannedFrom = this.bufferedAmount;
    const writes = [];
    for (const outgoing of this.order()) {
      while (outgoing.items.length && outgoing.items[0].offset >= outgoing.items[0].bytes.length) outgoing.items.shift();
      if (!outgoing.items.length || budget.bytes <= 0 || budget.writes <= 0) continue;
      if (outgoing.stream === null && !await this.open(outgoing)) continue;
      if (this.disposed) return [];
      if (!outgoing.items.length) continue;
      let index = 0, offset = outgoing.items[0].offset;
      for (let turn = 0; turn < (outgoing.short ? 1 : WRITES_PER_STREAM) && index < outgoing.items.length && budget.bytes > 0 && budget.writes > 0; turn++) {
        const item = outgoing.items[index];
        const bytes = item.bytes.subarray(offset, offset + Math.min(WRITE_CHUNK, budget.bytes));
        if (bytes.length) {
          writes.push({ channel: this, outgoing, bytes });
          budget.bytes -= bytes.length;
          budget.writes -= 1;
        }
        offset += bytes.length;
        if (offset >= item.bytes.length) {
          index++;
          offset = 0;
        }
      }
    }
    return writes;
  }
  /** `binary-io`: the engine took `written` of a planned write of `planned` bytes (-1: the connection is gone). */
  consume(outgoing, written, planned) {
    if (this.disposed) return;
    if (!Number.isInteger(written) || written < 0 || written > planned) {
      this.close({ drain: false });
      return;
    }
    outgoing.short = written < planned;
    for (let left = written; outgoing.items.length; ) {
      const item = outgoing.items[0], taken = Math.min(left, item.bytes.length - item.offset);
      item.offset += taken;
      left -= taken;
      outgoing.queued -= taken;
      if (outgoing.reserved) this.owner.release(taken);
      if (item.offset < item.bytes.length) break;
      outgoing.items.shift();
    }
  }
  /** `binary-io`: after the turn's `io` call, what `flush` does once its writes are done. */
  async afterWrites() {
    if (this.closeDeadline && now() >= this.closeDeadline) {
      this.dispose();
      return;
    }
    await this.drained(this.plannedFrom);
  }
  /**
   * Opens `outgoing`'s stream in the engine. A body the engine has no stream for yet (`STREAM_LIMIT`: earlier ones are not all
   * acknowledged) waits for the next turn; for the channel's own streams it is an error, as before.
   */
  async open(outgoing) {
    if (!(outgoing instanceof Body)) {
      outgoing.stream = await this.owner.call({ op: "openStream", id: this.id, priority: outgoing.priority });
      return true;
    }
    try {
      outgoing.stream = await this.owner.call({ op: "openStream", id: this.id, priority: outgoing.priority });
    } catch (error) {
      if (error?.message === "STREAM_LIMIT") return false;
      throw error;
    }
    return true;
  }
  async flushStream(outgoing) {
    if (!outgoing.items.length) return;
    if (outgoing.stream === null && !await this.open(outgoing)) return;
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
    if (!this.events.closed && state.path) {
      const tag = "link" in state.path ? "relay" : `${state.path.address}:${state.path.port}`;
      if (tag !== this.reportedPath) {
        this.reportedPath = tag;
        const current = this.path();
        for (const handler of this.pathHandlers) handler(current);
      }
    }
    const core = Array.isArray(state.buffered) ? new Map(state.buffered.map(([stream, bytes]) => [stream, bytes])) : null;
    for (const outgoing of [this.data, this.control, ...this.lanes ? Object.values(this.lanes) : [], ...this.bodies]) {
      outgoing.core = outgoing.stream === null || !core ? 0 : core.get(outgoing.stream) ?? 0;
    }
    if (this.bodies.some((body) => body.ended && body.core === 0)) this.bodies = this.bodies.filter((body) => !body.ended || body.core > 0);
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
      let data = chunk.data;
      if (stream.kind === null && data.length) {
        stream.kind = data[0];
        data = data.subarray(1);
      }
      if (stream.kind === DATA) {
        if (data.length) this.events.data(data);
        continue;
      }
      if (stream.kind === SESSION_BODY_KIND && this.owner.enhanced) {
        if (!this.bodiesDeclared) {
          this.close({ drain: false });
          return;
        }
        stream.head ?? (stream.head = []);
        while (stream.key == null && data.length) {
          stream.head.push(data[0]);
          data = data.subarray(1);
          if (stream.head.length === 4) stream.key = new DataView(Uint8Array.from(stream.head).buffer).getUint32(0, false);
        }
        if (stream.key != null && data.length) this.sessionBody(stream.key, data);
        if (this.disposed) return;
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
      const stream = this.streams.get(event.stream);
      if (stream?.kind === DATA) {
        this.close();
        return;
      }
      this.streams.delete(event.stream);
      if (stream?.kind === SESSION_BODY_KIND && stream.key != null && this.owner.enhanced) {
        this.sessionBody(stream.key, null);
        if (this.disposed) return;
      }
    }
    for (const [address, rttUs] of state.probeRtts ?? []) {
      if (this.router && address && typeof rttUs === "number") this.router.onProbeRtt(address, "link" in address, rttUs);
    }
    if (!this.router && !this.events.closed && now() >= this.nextProbe && this.candidates.length) {
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
      const candidates = value.candidates.filter((a) => a && typeof a.address === "string" && a.address.length <= 128 && Number.isInteger(a.port) && a.port > 0 && a.port <= 65535 && (!this.owner.publicOnly || !isPrivate(a.address)));
      if (this.owner.enhanced) candidates.sort((a, b) => Number(isPrivate(a.address)) - Number(isPrivate(b.address)));
      this.candidates = candidates.slice(0, MAX_CANDIDATES);
      this.candidateCursor = 0;
      this.nextProbe = 0;
      this.router?.setCandidates(this.candidates);
    }
    if (value) this.router?.onPeerPreference(value);
    if (value && typeof value === "object") this.router?.onPeerRelayVia(value);
  }
  /** Both paths' round trips as last measured and this side's preference (types.ts `PeerPathMetrics`). */
  pathMetrics() {
    if (this.router) return this.router.pathMetrics();
    const path = this.path(), rtt = (this.state?.rttUs ?? 0) > 0 ? this.state.rttUs / 1e3 : null;
    return { directRttMs: path === "direct" ? rtt : null, relayRttMs: path === "relay" ? rtt : null, preference: "auto" };
  }
  /** Prefer the direct or the relay path, or choose by round trip (`auto`); the peer is told and follows. */
  setPathPreference(preference) {
    this.router?.setPathPreference(preference);
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
  directAddress() {
    return this.events.closed || !this.state?.path || "link" in this.state.path ? null : this.state.path;
  }
  onPathChange(handler) {
    this.pathHandlers.push(handler);
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
    this.router?.stop();
    for (const item of this.data.items) this.owner.release(item.bytes.length - item.offset);
    for (const outgoing of [this.data, this.control, ...this.lanes ? Object.values(this.lanes) : [], ...this.bodies]) {
      outgoing.items = [];
      outgoing.queued = 0;
    }
    this.bodies = [];
    this.streams.clear();
    this.earlySession = [];
    this.earlyBodies = [];
    this.events.close();
    this.owner.detach(this.id);
  }
};
function isPrivate(address) {
  if (address.includes(":")) return /^(fe80:|fc|fd)/i.test(address);
  const [a, b] = address.split(".").map(Number);
  return a === 10 || a === 127 || a === 172 && b >= 16 && b < 32 || a === 192 && b === 168 || a === 100 && b >= 64 && b < 128 || a === 169 && b === 254;
}

// .cache/shared-task-portable-91179cedad/packages/agent-net/src/nativeMedia.ts
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
async function readNativeMedia(api, engine, id, headerSha256, write, options = {}) {
  const reader = await openNativeMediaReader(api, engine, id, headerSha256, options);
  try {
    return await reader.read(options.start ?? 0, options.end ?? reader.size - 1, write);
  } finally {
    await reader.close();
  }
}

// .cache/shared-task-portable-91179cedad/apps/harmony/native/portable/polyfill.ts
if (typeof globalThis.TextEncoder !== "function") globalThis.TextEncoder = class {
  encode(value = "") {
    const text = String(value), bytes = [];
    for (let i = 0; i < text.length; i++) {
      let cp = text.codePointAt(i);
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

// .cache/shared-task-portable-91179cedad/apps/harmony/entry/src/main/ets/core/shared-tasks/portable/SharingBridge.mjs
function parseSharingInvitation(input) {
  const parsed = parseAgentNetSharingInvitation(input, "shared-task");
  return parsed ? JSON.stringify(parsed) : "";
}
function buildSharingInvitation(receipt, server2, app) {
  return buildAgentNetSharingInvitation(JSON.parse(receipt), server2, app || "cindy");
}
async function deleteScopedAgentNetMedia(key3, scopeText, assertCurrent, remove) {
  assertCurrent();
  const scope = JSON.parse(scopeText), reference = parseAgentNetMediaKey(key3);
  if (!reference || !scope.sharedTaskId || reference.slot !== scope.slot || reference.networkId !== scope.networkId || reference.sharedTask && reference.sharedTask.sharedTaskId !== scope.sharedTaskId) throw new Error("AGENT_NET_MEDIA_SCOPE_MISMATCH");
  await remove(reference.id);
  assertCurrent();
}
async function createAgentNetSharing(configText, host) {
  const config = JSON.parse(configText);
  let closed = false, live = null, renewal = null;
  const guard = () => {
    if (closed) throw new Error("AGENT_NET_SHARING_CLOSED");
    host.check();
  };
  const command = (engine, input) => {
    guard();
    const response = JSON.parse(host.command(engine, JSON.stringify(input)));
    if (!response.ok) throw new Error(response.code || "AGENT_NET_ENGINE_FAILED");
    return response.value;
  };
  const signer = (engine) => ({
    identity: command(engine, { op: "identity" }),
    sign: async (text) => command(engine, { op: "sign", text }),
    random: async () => command(engine, { op: "random" })
  });
  const businessSigner = signer("business");
  let applicant = null, lease = null;
  const verify = (key3, text, signature) => command("business", { op: "verify", key: key3, text, signature }) === true;
  const verifyCertificate = (root, value, now2 = Date.now()) => certificatePolicyValid(value, now2) && verify(root, certificatePayload(value), value.signature);
  const verifyDelegation = (root, value, now2 = Date.now()) => delegationPolicyValid(value, now2) && verifyCertificate(root, value.issuerCertificate, now2) && !value.executors?.some((e) => !verifyCertificate(root, e.certificate, value.issuedAt)) && verify(value.issuerCertificate.signingKey, delegationPayload(value), value.signature);
  const fetch2 = async (address, options = {}) => {
    guard();
    if (options.signal?.aborted) throw new Error("AGENT_NET_CANCELLED");
    const binary = options.body instanceof Uint8Array;
    const response = JSON.parse(await host.request(
      address,
      options.method || "GET",
      JSON.stringify(options.headers || {}),
      binary ? toBase64Url(options.body) : options.body || "",
      binary
    ));
    guard();
    if (options.signal?.aborted) throw new Error("AGENT_NET_CANCELLED");
    const bytes = fromBase64Url(response.body);
    return {
      ok: response.status >= 200 && response.status < 300,
      status: response.status,
      headers: { get(name) {
        const key3 = Object.keys(response.headers || {}).find((k) => k.toLowerCase() === name.toLowerCase());
        return key3 ? response.headers[key3] : null;
      } },
      json: async () => JSON.parse(new TextDecoder().decode(bytes)),
      arrayBuffer: async () => bytes.buffer
    };
  };
  const wires = /* @__PURE__ */ new Set();
  const createWebSocket = (address, headers) => {
    guard();
    const socket = {
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
        wire.close();
        wires.delete(wire);
      }
    };
    const wire = host.socket(address, JSON.stringify(headers), {
      open() {
        socket.readyState = 1;
      },
      message(data, binary) {
        if (!closed) socket.onmessage?.({ data: binary ? fromBase64Url(data).buffer : data });
      },
      error() {
        socket.onerror?.({ message: "AGENT_NET_SHARING_NETWORK_ERROR" });
      },
      close(code) {
        socket.readyState = 3;
        socket.onclose?.({ code });
      }
    });
    wires.add(wire);
    return socket;
  };
  const business = new AgentNetSharingClient({
    base: config.server,
    networkId: config.networkId,
    rootPublicKey: config.rootPublicKey,
    privateSharing: config.v === 3,
    ownerPinnedHttp: config.ownerPinnedHttp === true,
    signer: businessSigner,
    assertCurrent: guard,
    hash: (bytes) => fromBase64Url(host.sha256(toBase64Url(bytes))),
    fetch: fetch2,
    getIdentityCard: async (nonce) => JSON.parse(await host.identityCard(nonce)),
    ...config.privateMember ? { memberAuthorization: (method, path, body) => host.memberAuthorization(method, path, body) } : {}
  });
  const guestSubject = config.v === 3 ? "guest:" + businessSigner.identity.signingKey : agentNetSharingSubject(config.accountId, config.localRegion, config.region);
  const mediaEngine = { command: async (input) => command("applicant", input), assertCurrent: guard };
  const slot = () => {
    const value = JSON.stringify(["cindy-agent-net/sharing-media-slot/2", config.rootPublicKey, config.networkId, "shared-task", config.resourceId, null]);
    const hex = Array.from(fromBase64Url(host.sha256(toBase64Url(new TextEncoder().encode(value)))), (byte) => byte.toString(16).padStart(2, "0")).join("").slice(0, 32);
    return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join("-");
  };
  let mediaActive = 0;
  const guestApi = (delegation) => new PortableAgentNetClient(
    config.server,
    applicant,
    delegation.issuerCertificate,
    config.rootPublicKey,
    { delegation, assertCurrent: guard, sha256: (bytes) => host.sha256(toBase64Url(bytes)), verifyCertificate, verifyDelegation, fetch: fetch2, createWebSocket }
  );
  const stop = () => {
    if (closed) return;
    closed = true;
    clearTimeout(renewal);
    live?.socket.close();
    lease?.close();
    business.close();
    for (const wire of wires) wire.close();
    wires.clear();
    host.destroy();
  };
  const renew = async () => {
    try {
      guard();
      const delegation = await lease.acquire();
      guard();
      const api = guestApi(delegation);
      await live.socket.replaceClient(api);
      guard();
      live.api = api;
      renewal = setTimeout(renew, Math.max(1e3, delegation.expiresAt - Date.now() - 6e4));
    } catch {
      if (!closed) renewal = setTimeout(renew, 5e3);
    }
  };
  return {
    subject() {
      return config.privateMember ? config.subject : guestSubject;
    },
    async request(path, method, body, timeoutMs = 12e3) {
      guard();
      const controller = new AbortController();
      let timer;
      try {
        const timeout = new Promise((_, reject) => {
          timer = setTimeout(() => {
            controller.abort();
            reject(new Error("AGENT_NET_SHARING_REQUEST_TIMEOUT"));
          }, Math.max(1, Math.min(15e3, timeoutMs)));
        });
        const work = business.request(path, { method, ...body ? { body: JSON.parse(body) } : {}, signal: controller.signal, isCurrent: () => {
          guard();
          return true;
        } });
        const value = await Promise.race([work, timeout]);
        guard();
        return JSON.stringify(value);
      } finally {
        clearTimeout(timer);
        controller.abort();
      }
    },
    async connect() {
      guard();
      if (live) throw new Error("AGENT_NET_SHARING_ALREADY_CONNECTED");
      try {
        applicant = signer("applicant");
        const expectedDevice = config.v === 3 ? guestSubject : config.deviceId;
        if (applicant.identity.deviceId !== expectedDevice) throw new Error("AGENT_NET_SHARING_APPLICANT_MISMATCH");
        lease = new AgentNetSharingTransport({
          client: business,
          applicant,
          assertCurrent: guard,
          verifyCertificate,
          verifyDelegation,
          scope: {
            kind: "shared-task",
            resourceId: config.resourceId,
            networkId: config.networkId,
            rootPublicKey: config.rootPublicKey,
            hostDeviceId: config.hostDeviceId,
            memberId: config.memberId,
            guestSubject
          }
        });
        const delegation = await lease.acquire();
        guard();
        const api = guestApi(delegation);
        const engine = { command: async (input) => command("transport", input), assertCurrent: guard, destroy: async () => host.destroyEngine("transport") };
        const socket = await AgentNetSocket.openWithBindings({
          client: api,
          scoped: true,
          userId: config.accountId,
          assertCurrent: guard,
          bindings: { verifyCertificate, verifyDelegation, createTransport: (options) => NativeTransport.create(engine, options) }
        });
        guard();
        live = { socket, api };
        socket.on("message", (message) => {
          if (!closed) host.message(typeof message === "string" ? message : message.toString());
        });
        socket.on("close", (code) => {
          if (!closed) {
            clearTimeout(renewal);
            host.close(code || 1006);
          }
        });
        socket.on("error", () => {
          if (!closed) host.error();
        });
        renewal = setTimeout(renew, Math.max(1e3, delegation.expiresAt - Date.now() - 6e4));
      } catch (error) {
        stop();
        throw error;
      }
    },
    async upload(size, contentType, read) {
      guard();
      if (!live || mediaActive >= 2) throw new Error("AGENT_NET_MEDIA_PEER_UNAVAILABLE");
      if (!Number.isSafeInteger(size) || size <= 0 || size > 2 * 1024 * 1024 * 1024) throw new Error("INVALID_MEDIA_SIZE");
      const target = live.socket.scopedPeerTarget(sharedTaskHostPeer(config.resourceId, config.hostDeviceId));
      if (!target) throw new Error("AGENT_NET_MEDIA_SCOPE_MISMATCH");
      mediaActive++;
      try {
        const result = await uploadNativeMedia(
          live.api,
          mediaEngine,
          target.relayId,
          target.transportKey,
          size,
          async (offset, length) => {
            guard();
            const bytes = fromBase64Url(await read(offset, length));
            guard();
            return bytes;
          },
          { assertCurrent: guard, binding: agentNetMediaBinding(slot()) }
        );
        guard();
        const key3 = buildAgentNetMediaKey({
          slot: slot(),
          networkId: live.api.certificate.networkId,
          grantId: live.api.delegation.id,
          sharedTask: { sharedTaskId: config.resourceId, deviceId: live.api.identity.deviceId },
          id: result.id,
          headerSha256: result.headerSha256,
          contentType
        });
        return JSON.stringify({ key: key3, sha256: result.sha256, size });
      } finally {
        mediaActive--;
      }
    },
    async download(key3, write) {
      guard();
      const reference = parseAgentNetMediaKey(key3);
      if (!live || !reference || reference.slot !== slot() || reference.networkId !== config.networkId || reference.sharedTask && reference.sharedTask.sharedTaskId !== config.resourceId || mediaActive >= 2) throw new Error("AGENT_NET_MEDIA_SCOPE_MISMATCH");
      mediaActive++;
      try {
        const result = await readNativeMedia(
          live.api,
          mediaEngine,
          reference.id,
          reference.headerSha256,
          async (bytes, offset) => {
            guard();
            await write(toBase64Url(bytes), offset);
            guard();
          },
          { assertCurrent: guard, binding: agentNetMediaBinding(slot()) }
        );
        guard();
        return JSON.stringify({ size: result.size, mimeType: reference.contentType });
      } finally {
        mediaActive--;
      }
    },
    async deleteMedia(key3) {
      guard();
      if (!live) throw new Error("AGENT_NET_MEDIA_SOURCE_UNAVAILABLE");
      if (mediaActive >= 2) throw new Error("BACKPRESSURE");
      mediaActive++;
      try {
        await deleteScopedAgentNetMedia(
          key3,
          JSON.stringify({ slot: slot(), networkId: config.networkId, sharedTaskId: config.resourceId }),
          guard,
          async (id) => {
            guard();
            await live.api.request("DELETE", "/media/" + id);
            guard();
          }
        );
      } finally {
        mediaActive--;
      }
    },
    send(text) {
      guard();
      if (!live) throw new Error("AGENT_NET_SHARING_NOT_CONNECTED");
      live.socket.send(text);
    },
    close: stop
  };
}
function installSharingWebApis(parseUrl, queryPairs) {
  class SharingSearchParams {
    constructor(value) {
      this.pairs = JSON.parse(queryPairs(value));
    }
    get(name) {
      return this.pairs.find((pair) => pair[0] === name)?.[1] ?? null;
    }
    getAll(name) {
      return this.pairs.filter((pair) => pair[0] === name).map((pair) => pair[1]);
    }
    keys() {
      return this.pairs.map((pair) => pair[0]).values();
    }
  }
  if (typeof globalThis.URL !== "function") globalThis.URL = class {
    constructor(value) {
      Object.assign(this, JSON.parse(parseUrl(String(value))));
    }
  };
  if (!Object.getOwnPropertyDescriptor(globalThis.URL.prototype, "origin"))
    Object.defineProperty(globalThis.URL.prototype, "origin", { get() {
      return this.protocol + "//" + this.host;
    }, configurable: true });
  if (!Object.getOwnPropertyDescriptor(globalThis.URL.prototype, "searchParams"))
    Object.defineProperty(globalThis.URL.prototype, "searchParams", { get() {
      return new SharingSearchParams((this.search || "").replace(/^\?/, ""));
    }, configurable: true });
}
export {
  buildSharingInvitation,
  createAgentNetSharing,
  deleteScopedAgentNetMedia,
  installSharingWebApis,
  parseSharingInvitation
};
