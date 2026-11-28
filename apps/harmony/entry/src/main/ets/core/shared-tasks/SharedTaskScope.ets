import { recordOrEmpty, readStr } from '../tasks/TaskModels';
import { sharedTaskId, sharedTaskHostPeerKey, SharedTaskFault } from './SharedTaskModels';

export const SHARED_TASK_SCOPE_CAPABILITY = 'shared-task-v2';
const ROUTED: string[] = ['link-open', 'link-accept', 'link-close', 'invoke', 'invoke-result', 'push'];
export interface SharedTaskEndpoint { role: string; memberId?: string; }
export interface SharedTaskScope { sharedTaskId: string; target: SharedTaskEndpoint; source?: SharedTaskEndpoint; }
export interface SharedTaskPeer { sharedTaskId: string; deviceId: string; role: string; memberId: string; }
export interface SharedTaskSocketIdentity { sharedTaskId: string; hostDeviceId: string; memberId: string; }
export function sharedTaskGuestPeerKey(id: string, memberId: string, device: string): string {
  if (!device || device.length > 128) throw new SharedTaskFault('invalid');
  const parts: Array<string | null> = [sharedTaskId(id), 'guest', sharedTaskId(memberId), device];
  return JSON.stringify(parts).padEnd(129, '~');
}
export function parseSharedTaskPeerKey(value: string): SharedTaskPeer | null {
  if (value.length <= 128 || value.length > 2048) return null;
  try {
    const parts = JSON.parse(value.replace(/~+$/, '')) as Object;
    if (!Array.isArray(parts) || parts.length !== 4) return null;
    const raw = parts as Object[];
    if (typeof raw[0] !== 'string' || typeof raw[1] !== 'string' || typeof raw[3] !== 'string') return null;
    const id = sharedTaskId(raw[0] as string), role = raw[1] as string, deviceId = raw[3] as string;
    if (!deviceId || deviceId.length > 128) return null;
    let memberId = '';
    if (role === 'host') { if (raw[2] !== null || value !== sharedTaskHostPeerKey(id, deviceId)) return null; }
    else if (role === 'guest' && typeof raw[2] === 'string') {
      memberId = sharedTaskId(raw[2] as string);
      if (value !== sharedTaskGuestPeerKey(id, memberId, deviceId)) return null;
    } else return null;
    return { sharedTaskId: id, role, memberId, deviceId };
  } catch { return null; }
}
function endpoint(raw: Object | undefined): SharedTaskEndpoint | null {
  const row = recordOrEmpty(raw), role = readStr(row, 'role');
  if (role === 'host' && row['memberId'] === undefined) return { role: 'host' };
  if (role === 'guest') {
    try { return { role: 'guest', memberId: sharedTaskId(readStr(row, 'memberId')) }; } catch { return null; }
  }
  return null;
}
export function parseSharedTaskWireScope(raw: Object | undefined, requireSource: boolean): SharedTaskScope | null {
  const row = recordOrEmpty(raw);
  try {
    const id = sharedTaskId(readStr(row, 'sharedTaskId')), target = endpoint(row['target']);
    if (!target) return null;
    const scope: SharedTaskScope = { sharedTaskId: id, target };
    if (requireSource) {
      const source = endpoint(row['source']);
      if (!source || source.role === target.role) return null;
      scope.source = source;
    }
    return scope;
  } catch { return null; }
}
export function withoutSharedTaskField(row: Record<string, Object>, field: string): Record<string, Object> {
  const next: Record<string, Object> = {};
  for (const key of Object.keys(row)) { if (key !== field) next[key] = row[key]; }
  return next;
}
/** Fixed upstream sharedTaskEnvelope semantics, restricted further to this one guest's host. */
export class SharedTaskScopeCodec {
  supported: boolean = false;
  selfDeviceId: string = '';
  private identity: SharedTaskSocketIdentity;
  private accountId: string;
  private physicalClient: boolean;
  constructor(identity: SharedTaskSocketIdentity, accountId: string, physicalClient: boolean = false) { this.identity = identity; this.accountId = accountId; this.physicalClient = physicalClient; }
  reset(): void { this.supported = false; this.selfDeviceId = ''; }
  encode(text: string): string {
    const row = recordOrEmpty(JSON.parse(text) as Object), kind = readStr(row, 'kind');
    if (row['v'] !== 1) throw new SharedTaskFault('invalid');
    if (kind === 'hello') {
      const payload = recordOrEmpty(row['payload']);
      // DlClient's subset does not preserve HelloPayload.capabilities; add at the socket boundary.
      payload['capabilities'] = [SHARED_TASK_SCOPE_CAPABILITY]; payload['remoteControlEnabled'] = false;
      row['payload'] = payload;
      if (row['sharedTask'] !== undefined || row['providerShare'] !== undefined || readStr(row, 'dst')) throw new SharedTaskFault('invalid');
      return JSON.stringify(row);
    }
    if (kind === 'ping' || kind === 'presence-set') {
      if (readStr(row, 'dst') || row['sharedTask'] !== undefined || row['providerShare'] !== undefined) throw new SharedTaskFault('invalid');
      return JSON.stringify(row);
    }
    const destination = readStr(row, 'dst');
    const peer = this.physicalClient && destination === this.identity.hostDeviceId
      ? parseSharedTaskPeerKey(sharedTaskHostPeerKey(this.identity.sharedTaskId, this.identity.hostDeviceId)) : parseSharedTaskPeerKey(destination);
    if (!this.supported) throw new SharedTaskFault('VERSION_MISMATCH');
    if (!ROUTED.includes(kind) || !peer || peer.role !== 'host' || peer.sharedTaskId !== this.identity.sharedTaskId
      || peer.deviceId !== this.identity.hostDeviceId || row['providerShare'] !== undefined) throw new SharedTaskFault('invalid');
    const target: SharedTaskEndpoint = { role: 'host' };
    const scope: SharedTaskScope = { sharedTaskId: peer.sharedTaskId, target };
    const outgoing = withoutSharedTaskField(row, 'src'); outgoing['dst'] = peer.deviceId; outgoing['sharedTask'] = scope;
    return JSON.stringify(outgoing);
  }
  decode(text: string): string | null {
    try {
      const row = recordOrEmpty(JSON.parse(text) as Object), kind = readStr(row, 'kind');
      if (row['v'] !== 1) return null;
      if (row['providerShare'] !== undefined) return null;
      if (kind === 'hello-ack') {
        if (row['sharedTask'] !== undefined) return null;
        const payload = recordOrEmpty(row['payload']);
        const caps = payload['capabilities'];
        if (readStr(payload, 'userId') !== this.accountId || readStr(payload, 'deviceId').length < 1
          || readStr(payload, 'deviceId').length > 128) throw new SharedTaskFault('ACCESS_REVOKED');
        this.selfDeviceId = readStr(payload, 'deviceId');
        this.supported = Array.isArray(caps) && (caps as Object[]).includes(SHARED_TASK_SCOPE_CAPABILITY);
        if (!this.supported) throw new SharedTaskFault('VERSION_MISMATCH');
        return text;
      }
      if (kind === 'pong') return row['sharedTask'] === undefined && !readStr(row, 'src') ? text : null;
      // A dedicated guest connection never consumes full-device presence or unscoped routed replies.
      if (!this.supported || (!ROUTED.includes(kind) && kind !== 'relay-error')) return null;
      const scope = parseSharedTaskWireScope(row['sharedTask'], kind !== 'relay-error');
      if (!scope || scope.sharedTaskId !== this.identity.sharedTaskId) return null;
      if (kind === 'relay-error') {
        const payload = recordOrEmpty(row['payload']);
        if (scope.target.role !== 'host' || readStr(payload, 'dst') !== this.identity.hostDeviceId) return null;
        payload['dst'] = this.physicalClient ? this.identity.hostDeviceId : sharedTaskHostPeerKey(scope.sharedTaskId, this.identity.hostDeviceId); row['payload'] = payload;
        return JSON.stringify(row);
      }
      if (scope.source?.role !== 'host' || scope.target.role !== 'guest' || scope.target.memberId !== this.identity.memberId
        || readStr(row, 'src') !== this.identity.hostDeviceId
        || (readStr(row, 'dst') && readStr(row, 'dst') !== this.selfDeviceId)) return null;
      row['src'] = this.physicalClient ? this.identity.hostDeviceId : sharedTaskHostPeerKey(scope.sharedTaskId, this.identity.hostDeviceId);
      row['dst'] = this.physicalClient ? this.selfDeviceId : sharedTaskGuestPeerKey(scope.sharedTaskId, this.identity.memberId, this.selfDeviceId);
      return JSON.stringify(row);
    } catch (error) { if (error instanceof SharedTaskFault) throw error; return null; }
  }
}
