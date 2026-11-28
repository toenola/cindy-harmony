import { recordOrEmpty, readStr, readNum } from '../tasks/TaskModels';

export interface SharedTaskMember { memberId: string; accountId: string; version: number; deviceIds: string[];
  displayName: string; joinedAt: number | null; }
export interface SharedTaskItem { sharedTaskId: string; sessionId: string; ownerAccountId: string;
  hostDeviceId: string; title: string; revision: number; }
export interface SharedTaskDetail extends SharedTaskItem { status: string; guests: SharedTaskMember[]; }
export interface SharedTaskListing { items: SharedTaskItem[]; unavailableSharedTaskIds: string[]; authorityIncomplete: boolean; }
export interface SharedTaskRequest { method: string; body?: Object; isCurrent: () => boolean; }
export interface SharedTaskInvitation { kind: string; invitation: string; server: string; sharedTaskId: string; }
export interface SharedTaskJoinBody { invitation: string; displayName: string; }
export interface SharedTaskHostCommand { action: string; sessionId?: string; sharedTaskId?: string; memberId?: string; }
export interface SharedTaskSessionTarget { sharedTaskId: string; sessionId: string; peer: string;
  hostDeviceId: string; ownerAccountId: string; title: string; guest: boolean; transport: string; }
/** Authenticated task-specific transport. No full-device fallback is permitted. */
export interface SharedTaskGuestTransport {
  target: SharedTaskSessionTarget;
  invoke: (channel: string, args: Object[]) => Promise<Object | undefined>;
  subscribe: (listener: (channel: string, payload: Object) => void) => () => void;
  // Shared media route only: task-scoped OSS or Agent-Net media backend. Host checks each reference.
  upload: (localUri: string, name: string, mime: string) => Promise<string>;
  fetch: (reference: string) => Promise<Object | undefined>;
  delete?: (key: string) => Promise<void>;
  onRevoked: (listener: () => void) => () => void;
  close: () => void;
}
export interface SharedTasksHost {
  // Host uses official API base or already pinned Agent-Net authority. Never the current control relay by default.
  request: (path: string, options: SharedTaskRequest) => Promise<Object | undefined>;
  ownerInvoke: (deviceId: string, command: SharedTaskHostCommand) => Promise<Object | undefined>;
  parseInvitation: (input: string) => SharedTaskInvitation | null;
  join: (invitation: SharedTaskInvitation, displayName: string, isCurrent: () => boolean) => Promise<Object | undefined>;
  openGuest: (detail: SharedTaskDetail) => Promise<SharedTaskGuestTransport>;
  openOwner: (detail: SharedTaskDetail) => Promise<void>;
  invitationLink: (invitation: string, detail: SharedTaskDetail) => string;
  dispose?: () => void;
}
export class SharedTaskFault extends Error {
  code: string;
  status: number;
  constructor(code: string, status: number = 0) { super(code); this.code = code; this.status = status; }
}
/** Keep protocol error codes/status without throwing arbitrary objects or exposing raw payloads. */
export function sharedTaskError(error: Object | undefined): Error {
  if (error instanceof Error) return error;
  const row = recordOrEmpty(error);
  return new SharedTaskFault(readStr(row, 'code') || 'failed', readNum(row, 'status', 0));
}
export function sharedTaskId(value: string): string {
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(value)) throw new SharedTaskFault('invalid');
  return value;
}
export function parseSharedTaskItem(raw: Object): SharedTaskItem {
  const row = recordOrEmpty(raw), revision = readNum(row, 'revision', 0), title = readStr(row, 'title');
  if (!Number.isSafeInteger(revision) || revision < 1 || !title.trim() || title.length > 128 || /[\u0000-\u001f\u007f]/.test(title)) throw new SharedTaskFault('invalid');
  const hostDeviceId = readStr(row, 'hostDeviceId');
  // Physical IDs allow the same syntax and length as existing shared-task device claims.
  if (!hostDeviceId || hostDeviceId.length > 128) throw new SharedTaskFault('invalid');
  return { sharedTaskId: sharedTaskId(readStr(row, 'sharedTaskId')), sessionId: sharedTaskId(readStr(row, 'sessionId')),
    ownerAccountId: sharedTaskId(readStr(row, 'ownerAccountId')), hostDeviceId, title, revision };
}
export function parseSharedTaskDetail(raw: Object | undefined, expectedId: string): SharedTaskDetail {
  const row = recordOrEmpty(raw), item = parseSharedTaskItem(row), status = readStr(row, 'status');
  if (item.sharedTaskId !== expectedId || (status !== 'active' && status !== 'closed') || !Array.isArray(row['guests'])) throw new SharedTaskFault('invalid');
  const guests: SharedTaskMember[] = [];
  const accounts: Set<string> = new Set([item.ownerAccountId]), members: Set<string> = new Set();
  // Admission limits belong to the authority; do not hardcode current quotas into the client.
  if ((row['guests'] as Object[]).length > 10000) throw new SharedTaskFault('invalid');
  for (const value of row['guests'] as Object[]) {
    const guest = recordOrEmpty(value), memberId = sharedTaskId(readStr(guest, 'memberId')), accountId = sharedTaskId(readStr(guest, 'accountId'));
    const version = readNum(guest, 'version', 0);
    let displayName = readStr(guest, 'displayName');
    let joinedValue = guest['joinedAt'];
    if (!displayName && Array.isArray(row['memberLabels'])) {
      for (const rawLabel of row['memberLabels'] as Object[]) {
        const label = recordOrEmpty(rawLabel);
        if (readStr(label, 'memberId') === memberId) { displayName = readStr(label, 'displayName'); joinedValue = label['joinedAt']; break; }
      }
    }
    if (members.has(memberId) || accounts.has(accountId) || !Number.isSafeInteger(version) || version < 1
      || !displayName.trim() || displayName.length > 128 || !Array.isArray(guest['deviceIds']) || (guest['deviceIds'] as Object[]).length > 64) throw new SharedTaskFault('invalid');
    const devices: string[] = [];
    for (const device of guest['deviceIds'] as Object[]) {
      if (typeof device !== 'string' || !device || device.length > 128 || devices.includes(device)) throw new SharedTaskFault('invalid');
      devices.push(device);
    }
    members.add(memberId); accounts.add(accountId);
    const joinedAt = joinedValue;
    if (joinedAt !== null && (typeof joinedAt !== 'number' || !Number.isSafeInteger(joinedAt) || joinedAt < 0)) throw new SharedTaskFault('invalid');
    guests.push({ memberId, accountId, version, deviceIds: devices, displayName, joinedAt: joinedAt as number | null });
  }
  return { sharedTaskId: item.sharedTaskId, sessionId: item.sessionId, ownerAccountId: item.ownerAccountId,
    hostDeviceId: item.hostDeviceId, title: item.title, revision: item.revision, status, guests };
}
export function sharedTaskFailure(error: Object): string {
  const row = recordOrEmpty(error), code = readStr(row, 'code'), status = readNum(row, 'status', 0);
  if ((status === 404 && code === 'NOT_FOUND') || code === 'ACCESS_REVOKED' || code === 'SHARED_TASK_CLOSED') return 'ended';
  if (code === 'SHARED_TASK_SELF_JOIN') return 'self';
  if (/LIMIT|FULL/.test(code)) return 'full';
  if (/INVITATION|INVITE/.test(code)) return 'invitation';
  if (/UNSUPPORTED|VERSION_MISMATCH|CHANNEL_NOT_ALLOWED/.test(code)) return 'unsupported';
  if (/PERMISSION_DENIED|FORBIDDEN/.test(code)) return 'forbidden';
  return 'failed';
}
export function sharedTaskDisplayName(name: string): string {
  const text = name.replace(/[\u0000-\u001f\u007f]/g, '').trim();
  let end = Math.min(text.length, 32);
  if (end < text.length && /[\uD800-\uDBFF]/.test(text[end - 1]) && /[\uDC00-\uDFFF]/.test(text[end])) end--;
  return text.slice(0, end) || 'Cindy';
}
/** UI projection only; executing host independently checks membership and every action. */
export function sharedTaskCan(guest: boolean, operation: string, ownPending: boolean = false, hostOwnedConfirmation: boolean = false): boolean {
  if (!guest) return true;
  if (operation === 'approval.resolve') return !hostOwnedConfirmation;
  if (operation === 'input.edit' || operation === 'input.withdraw') return ownPending;
  return ['history.read', 'events.subscribe', 'attachment.read', 'attachment.upload', 'file.read', 'file.write', 'input.send', 'agent.stop'].includes(operation);
}

export class SharedTaskEmptyBody {}
export function sharedTaskHostPeerKey(id: string, deviceId: string): string {
  if (!deviceId || deviceId.length > 128) throw new SharedTaskFault('invalid');
  const parts: Array<string | null> = [sharedTaskId(id), 'host', null, deviceId];
  return JSON.stringify(parts).padEnd(129, '~');
}
/** Unsupported host is explicit; it cannot create a fake owner or route. */
export class UnavailableSharedTasksHost implements SharedTasksHost {
  async request(_path: string, _options: SharedTaskRequest): Promise<Object | undefined> { throw new SharedTaskFault('unsupported'); }
  async ownerInvoke(_deviceId: string, _command: SharedTaskHostCommand): Promise<Object | undefined> { throw new SharedTaskFault('unsupported'); }
  parseInvitation(_input: string): SharedTaskInvitation | null { return null; }
  async join(_invitation: SharedTaskInvitation, _displayName: string, _current: () => boolean): Promise<Object | undefined> { throw new SharedTaskFault('unsupported'); }
  async openGuest(_detail: SharedTaskDetail): Promise<SharedTaskGuestTransport> { throw new SharedTaskFault('unsupported'); }
  async openOwner(_detail: SharedTaskDetail): Promise<void> { throw new SharedTaskFault('unsupported'); }
  invitationLink(_invitation: string, _detail: SharedTaskDetail): string { throw new SharedTaskFault('unsupported'); }
}
