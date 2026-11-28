import { recordOrEmpty, readStr } from '../tasks/TaskModels';
import { SharedTasksHost, SharedTaskMember, SharedTaskItem, SharedTaskDetail, SharedTaskRequest, SharedTaskHostCommand,
  SharedTaskFault, SharedTaskEmptyBody, sharedTaskHostPeerKey, SharedTaskGuestTransport, parseSharedTaskItem, parseSharedTaskDetail,
  sharedTaskId, sharedTaskFailure, sharedTaskDisplayName, sharedTaskError } from './SharedTaskModels';
import { SharedTaskAccess } from './SharedTaskAccess';

const API = '/api/device-link/shared-tasks';
export class SharedTasksStore {
  items: SharedTaskItem[] = [];
  detail: SharedTaskDetail | null = null;
  access: SharedTaskAccess | null = null;
  invitation: string = '';
  issue: string = '';
  busy: boolean = false;
  loading: boolean = false;
  loaded: boolean = false;
  ended: boolean = false;
  private host: SharedTasksHost;
  private accountId: string = '';
  private accountName: string = '';
  private scope: string = '';
  private generation: number = 0;
  private visible: boolean = false;
  private taskVisible: boolean = false;
  private readRevision: number = 0;
  private online: boolean = false;
  private selectedId: string = '';
  private ownerDeviceId: string = '';
  private ownerSessionId: string = '';
  private timer: number = -1;
  private operation: Promise<void> | null = null;
  private pending: boolean = false;
  private listeners: Array<() => void> = [];
  constructor(host: SharedTasksHost) { this.host = host; }
  identity(): string { return this.scope; }
  owned(): SharedTaskItem[] { return this.items.filter((item: SharedTaskItem): boolean => item.ownerAccountId === this.accountId); }
  joined(): SharedTaskItem[] { return this.items.filter((item: SharedTaskItem): boolean => item.ownerAccountId !== this.accountId); }
  isOwner(): boolean { return !!this.detail && this.detail.ownerAccountId === this.accountId; }
  onChanged(listener: () => void): () => void {
    this.listeners.push(listener);
    return (): void => { this.listeners = this.listeners.filter((entry: () => void): boolean => entry !== listener); };
  }
  private emit(): void { this.listeners.forEach((listener: () => void): void => listener()); }
  configure(scope: string, accountId: string, accountName: string, online: boolean): void {
    const changed = scope !== this.scope || accountId !== this.accountId;
    const restored = online && !this.online;
    if (changed) {
      this.generation++; this.access?.close(); this.access = null; this.items = []; this.detail = null;
      this.selectedId = ''; this.ownerDeviceId = ''; this.ownerSessionId = ''; this.invitation = ''; this.issue = ''; this.loaded = false; this.ended = false;
      this.scope = scope; this.accountId = accountId; this.busy = false; this.pending = !!this.operation;
    }
    this.accountName = accountName; this.online = online;
    if (!online) this.clearTimer();
    if ((changed || restored) && (this.visible || this.taskVisible) && online) void this.refresh();
    this.emit();
  }
  setVisible(value: boolean): void { this.visible = value; if (!value) { this.clearTimer(); this.invitation = ''; this.schedule(); } else void this.refresh(); }
  setTaskVisible(value: boolean): void { this.taskVisible = value; if (value) void this.refresh(); else this.schedule(); }
  private current(generation: number): boolean { return generation === this.generation && !!this.scope && !!this.accountId; }
  private clearTimer(): void { if (this.timer >= 0) clearTimeout(this.timer); this.timer = -1; }
  private schedule(): void {
    this.clearTimer();
    if ((this.ended && !this.access?.active) || (!this.visible && !this.taskVisible) || !this.online || !this.accountId) return;
    // Official access watch: 5s while a guest task is open; directory discovery 30/60s.
    const delay = this.access?.active ? 5000 : this.items.length ? 30000 : 60000;
    this.timer = setTimeout((): void => { this.timer = -1; void this.refresh(); }, delay);
  }
  private async request(path: string, method: string = 'GET', body?: Object): Promise<Object | undefined> {
    const generation = this.generation;
    const options: SharedTaskRequest = { method, isCurrent: (): boolean => this.current(generation) };
    if (body !== undefined) options.body = body;
    if (!options.isCurrent()) throw new SharedTaskFault('ACCESS_REVOKED');
    const value = await this.host.request(API + path, options);
    if (!options.isCurrent()) throw new SharedTaskFault('ACCESS_REVOKED');
    return value;
  }
  refresh(): Promise<void> {
    if ((this.ended && !this.access?.active) || (!this.visible && !this.taskVisible) || !this.online || !this.accountId || this.busy) return Promise.resolve();
    if (this.operation) { this.pending = true; return this.operation; }
    this.clearTimer(); this.loading = true; const generation = this.generation;
    const revision = this.readRevision;
    const operation = this.read(generation, revision).finally((): void => {
      if (this.operation !== operation) return;
      this.operation = null; this.loading = false; this.emit();
      if (this.pending) { this.pending = false; void this.refresh(); } else this.schedule();
    });
    this.operation = operation; this.emit(); return operation;
  }
  private async read(generation: number, revision: number): Promise<void> {
    try {
      const watched = this.taskVisible ? this.access : null;
      if (watched?.active && watched.target.sharedTaskId !== this.selectedId) {
        const id = watched.target.sharedTaskId;
        try {
          const currentDetail = parseSharedTaskDetail(await this.request('/' + encodeURIComponent(id)), id);
          if (!this.current(generation) || revision !== this.readRevision || this.access !== watched) return;
          if (currentDetail.status === 'closed') { this.endAccess(id); return; }
          if (currentDetail.sessionId !== watched.target.sessionId) throw new SharedTaskFault('invalid');
        } catch (error) {
          if (!this.current(generation) || revision !== this.readRevision || this.access !== watched) return;
          if (sharedTaskFailure(error as Object) === 'ended') { this.endAccess(id); return; }
          throw sharedTaskError(error);
        }
      }
      if (this.selectedId) {
        const selected = this.selectedId;
        const detail = parseSharedTaskDetail(await this.request('/' + encodeURIComponent(selected)), selected);
        if (!this.current(generation) || revision !== this.readRevision || this.selectedId !== selected) return;
        if (detail.status === 'closed') { this.endAccess(selected); return; }
        if (this.access && detail.sessionId !== this.access.target.sessionId) throw new SharedTaskFault('invalid');
        this.detail = detail;
      } else if (this.ownerDeviceId && this.ownerSessionId) {
        const command: SharedTaskHostCommand = { action: 'state', sessionId: this.ownerSessionId };
        const raw = recordOrEmpty(await this.host.ownerInvoke(this.ownerDeviceId, command));
        if (!this.current(generation) || revision !== this.readRevision) return;
        if (raw['available'] !== true) { this.issue = 'unsupported'; return; }
        const detail = recordOrEmpty(raw['detail']), id = readStr(detail, 'sharedTaskId');
        this.detail = id ? parseSharedTaskDetail(detail, id) : null;
        if (this.detail && (this.detail.ownerAccountId !== this.accountId || this.detail.sessionId !== this.ownerSessionId)) throw new SharedTaskFault('invalid');
      } else {
        const raw = recordOrEmpty(await this.request(''));
        if (!this.current(generation) || revision !== this.readRevision) return;
        if (!Array.isArray(raw['sharedTasks']) || (raw['sharedTasks'] as Object[]).length > 10000) throw new SharedTaskFault('invalid');
        const items: SharedTaskItem[] = [], seen: Set<string> = new Set();
        for (const value of raw['sharedTasks'] as Object[]) {
          const item = parseSharedTaskItem(value);
          if (seen.has(item.sharedTaskId)) throw new SharedTaskFault('invalid');
          seen.add(item.sharedTaskId); items.push(item);
        }
        // A partial multi-authority list does not revoke memberships omitted by an unavailable authority.
        if (raw['authorityIncomplete'] === true || Array.isArray(raw['unavailableSharedTaskIds'])) {
          const unavailable = Array.isArray(raw['unavailableSharedTaskIds']) ? raw['unavailableSharedTaskIds'] as string[] : [];
          for (const old of this.items) {
            if (!seen.has(old.sharedTaskId) && (raw['authorityIncomplete'] === true || unavailable.includes(old.sharedTaskId))) items.push(old);
          }
        }
        this.items = items;
      }
      this.loaded = true; this.issue = '';
    } catch (error) {
      if (!this.current(generation) || revision !== this.readRevision) return;
      const issue = error instanceof SharedTaskFault && ['invalid', 'invitation', 'different-server', 'unsupported', 'forbidden', 'ended'].includes(error.code) ? error.code : sharedTaskFailure(error as Object);
      if (issue === 'ended' && this.selectedId) this.endAccess(this.selectedId); else this.issue = issue;
    }
  }
  showList(): void { this.readRevision++; this.selectedId = ''; this.ownerDeviceId = ''; this.ownerSessionId = ''; this.detail = null; this.invitation = ''; this.ended = false; void this.refresh(); }
  select(sharedTaskId: string): void { this.readRevision++; this.selectedId = sharedTaskId; this.ownerDeviceId = ''; this.ownerSessionId = ''; this.detail = null; this.invitation = ''; this.ended = false; this.pending = !!this.operation; void this.refresh(); }
  selectOwnerTask(deviceId: string, sessionId: string): void { this.readRevision++;
    this.selectedId = ''; this.ownerDeviceId = deviceId; this.ownerSessionId = sessionId;
    this.detail = null; this.invitation = ''; this.ended = false; this.pending = !!this.operation; void this.refresh();
  }
  private async mutate(work: (current: () => boolean) => Promise<void>): Promise<void> {
    if (this.busy || !this.online || !this.accountId) return;
    const generation = this.generation; this.readRevision++; this.busy = true; this.issue = ''; this.clearTimer(); this.emit();
    try { await work((): boolean => this.current(generation)); }
    catch (error) { if (this.current(generation)) this.issue = error instanceof SharedTaskFault && ['invalid', 'invitation', 'different-server', 'unsupported', 'forbidden', 'ended'].includes(error.code) ? error.code : sharedTaskFailure(error as Object); }
    finally { if (this.current(generation)) { this.busy = false; this.emit(); this.schedule(); } }
  }
  join(input: string): Promise<void> {
    return this.mutate(async (current: () => boolean): Promise<void> => {
      const invitation = this.host.parseInvitation(input);
      if (!invitation || !['official', 'agent-net'].includes(invitation.kind)) throw new SharedTaskFault('invitation');
      const result = recordOrEmpty(await this.host.join(invitation, sharedTaskDisplayName(this.accountName), current));
      if (!current()) return;
      if (result['status'] !== 'joined' || typeof result['created'] !== 'boolean') throw new SharedTaskFault('invalid');
      const id = sharedTaskId(readStr(result, 'sharedTaskId')); sharedTaskId(readStr(result, 'memberId'));
      if (invitation.sharedTaskId && id !== invitation.sharedTaskId) throw new SharedTaskFault('invalid');
      await this.openInternal(id, current);
    });
  }
  open(id: string): Promise<void> { return this.mutate(async (current: () => boolean): Promise<void> => this.openInternal(id, current)); }
  private async openInternal(id: string, current: () => boolean): Promise<void> {
    const detail = parseSharedTaskDetail(await this.request('/' + encodeURIComponent(sharedTaskId(id))), id);
    if (!current()) return;
    if (detail.status !== 'active') throw new SharedTaskFault('ended');
    this.detail = detail; this.selectedId = id;
    if (detail.ownerAccountId === this.accountId) { await this.host.openOwner(detail); return; }
    const transport = await this.host.openGuest(detail);
    if (!current()) { transport.close(); return; }
    const target = transport.target;
    if (!target.guest || !['official-scoped', 'agent-net'].includes(target.transport)
      || target.sharedTaskId !== id || target.sessionId !== detail.sessionId || target.ownerAccountId !== detail.ownerAccountId
      || target.hostDeviceId !== detail.hostDeviceId || target.peer === detail.hostDeviceId || target.peer !== sharedTaskHostPeerKey(id, detail.hostDeviceId)) {
      transport.close(); throw new SharedTaskFault('unsupported');
    }
    this.access?.close();
    this.access = new SharedTaskAccess(transport, current, (): void => this.endAccess(id)); this.emit();
  }
  start(): Promise<void> {
    return this.mutate(async (current: () => boolean): Promise<void> => {
      if (!this.ownerDeviceId || !this.ownerSessionId) throw new SharedTaskFault('forbidden');
      const command: SharedTaskHostCommand = { action: 'open', sessionId: this.ownerSessionId };
      await this.host.ownerInvoke(this.ownerDeviceId, command);
      if (!current()) return;
      // Host creates/reuses the sharing lifetime. Never call the account create endpoint from a phone.
      const stateCommand: SharedTaskHostCommand = { action: 'state', sessionId: this.ownerSessionId };
      const state = recordOrEmpty(await this.host.ownerInvoke(this.ownerDeviceId, stateCommand));
      if (!current()) return;
      const row = recordOrEmpty(state['detail']), id = readStr(row, 'sharedTaskId');
      this.detail = parseSharedTaskDetail(row, id);
      if (this.detail.ownerAccountId !== this.accountId || this.detail.sessionId !== this.ownerSessionId) throw new SharedTaskFault('invalid');
    });
  }
  invite(): Promise<void> {
    return this.mutate(async (current: () => boolean): Promise<void> => {
      const detail = this.detail;
      if (!detail || !this.isOwner()) throw new SharedTaskFault('forbidden');
      const command: SharedTaskHostCommand = { action: 'invite', sharedTaskId: detail.sharedTaskId };
      const value = recordOrEmpty(await this.host.ownerInvoke(detail.hostDeviceId, command));
      if (!current()) return;
      const invitation = readStr(value, 'invitation');
      if (!invitation) throw new SharedTaskFault('invalid');
      this.invitation = this.host.invitationLink(invitation, detail);
    });
  }
  remove(memberId: string): Promise<void> {
    return this.mutate(async (current: () => boolean): Promise<void> => {
      const detail = this.detail;
      if (!detail || !this.isOwner() || !detail.guests.some((member: SharedTaskMember): boolean => member.memberId === memberId)) throw new SharedTaskFault('forbidden');
      const command: SharedTaskHostCommand = { action: 'remove', sharedTaskId: detail.sharedTaskId, memberId };
      const response = recordOrEmpty(await this.host.ownerInvoke(detail.hostDeviceId, command));
      if (response['ok'] !== true) throw new SharedTaskFault('invalid');
      if (current()) { this.invitation = ''; this.detail = null; this.pending = true; }
    }).then((): void => { if (this.pending) { this.pending = false; void this.refresh(); } });
  }
  leave(): Promise<void> {
    return this.mutate(async (current: () => boolean): Promise<void> => {
      if (!this.detail || this.isOwner()) throw new SharedTaskFault('forbidden');
      const response = recordOrEmpty(await this.request('/' + encodeURIComponent(this.detail.sharedTaskId) + '/leave', 'POST', new SharedTaskEmptyBody()));
      if (readStr(response, 'status') !== 'left') throw new SharedTaskFault('invalid');
      if (current()) this.endAccess();
    });
  }
  closeSharing(): Promise<void> {
    return this.mutate(async (current: () => boolean): Promise<void> => {
      const detail = this.detail;
      if (!detail || !this.isOwner()) throw new SharedTaskFault('forbidden');
      const command: SharedTaskHostCommand = { action: 'close', sharedTaskId: detail.sharedTaskId };
      const response = recordOrEmpty(await this.host.ownerInvoke(detail.hostDeviceId, command));
      if (response['ok'] !== true) throw new SharedTaskFault('invalid');
      if (current()) this.endAccess();
    });
  }
  private endAccess(id: string = this.selectedId || this.detail?.sharedTaskId || ''): void {
    this.readRevision++;
    if (!id || this.access?.target.sharedTaskId === id) { this.taskVisible = false; this.access?.close(); this.access = null; }
    if (!id || !this.selectedId || this.selectedId === id || this.detail?.sharedTaskId === id) {
      this.detail = null; this.invitation = ''; this.ended = true; this.issue = 'ended';
    }
    this.emit();
  }
  membershipChanged(): void { this.pending = !!this.operation; if (!this.busy) void this.refresh(); }
  dispose(): void { this.generation++; this.clearTimer(); this.visible = false; this.access?.close(); this.access = null;
    this.items = []; this.detail = null; this.invitation = ''; this.listeners = []; }
}
